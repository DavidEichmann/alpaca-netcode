{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_HADDOCK not-home #-}

-- | Rollback and replay based game networking
module Alpaca.NetCode
  ( -- * Simplified API
    -- | This should be all you need to get started. See the extended API below
    -- if you'd like to further configure things.
    runServer,
    runClient,
    -- ** Types
    Core.Tick (..),
    Core.PlayerId (..),
    HostName,
    ServiceName,
    -- * Extended API
    -- ** Server
    runServerWith,
    Core.ServerConfig (..),
    Core.defaultServerConfig,
    -- ** Client
    runClientWith,
    Core.ClientConfig (..),
    Core.defaultClientConfig,
    Core.SimNetConditions (..),
  ) where

import qualified Alpaca.NetCode.Core as Core
import Alpaca.NetCode.Core.Common
import Control.Concurrent (
  Chan,
  forkIO,
  newChan,
  readChan,
  writeChan,
 )
import qualified Control.Exception as E
import Control.Monad
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map as M
import Flat (
  DecodeException (BadEncoding),
  Flat,
  flat,
  unflat,
 )
import Network.Run.UDP (runUDPServer)
import Network.Socket (
  AddrInfo (
    addrAddress,
    addrFamily,
    addrFlags,
    addrProtocol,
    addrSocketType
  ),
  AddrInfoFlag (AI_PASSIVE),
  HostName,
  ServiceName,
  SockAddr,
  Socket,
  SocketType (Datagram),
  close,
  connect,
  defaultHints,
  getAddrInfo,
  socket,
  withSocketsDo,
 )
import qualified Network.Socket.ByteString as NBS

-- | Start a client. This blocks until the initial handshake with the server is
-- finished.
runClient ::
  forall world input.
  Flat input =>
  -- | The server's host name or IP address.
  HostName ->
  -- | The server's port number e.g. @"8111"@.
  ServiceName ->
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
  Int ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server.
  input ->
  -- | Initial world state. Must be the same across all clients.
  world ->
  -- | A deterministic stepping function (for a single tick). Must be the same
  -- across all clients and the server. Takes:
  --
  -- * a map from PlayerId to current input.
  -- * current game tick.
  -- * previous tick's world state
  --
  -- It is important that this is deterministic else clients' states will
  -- diverge. Beware of floating point non-determinism!
  ( M.Map Core.PlayerId input ->
    Core.Tick ->
    world ->
    world
  ) ->
  IO (Core.Client world input)
runClient
  serverHostName
  serverPort
  tickRate
  input0
  world0
  stepOneTick
  = runClientWith
      serverHostName
      serverPort
      Nothing
      (Core.defaultClientConfig tickRate)
      input0
      world0
      stepOneTick

-- | Start a client. This blocks until the initial handshake with the server is
-- finished.
runClientWith ::
  forall world input.
  Flat input =>
  -- | The server's host name or IP address.
  HostName ->
  -- | The server's port number.
  ServiceName ->
  -- | Optional simulation of network conditions. In production this should be
  -- `Nothing`. May differ between clients.
  Maybe SimNetConditions ->
  -- | The 'Alpaca.NetCode.Core.defaultClientConfig' works well for most cases.
  Core.ClientConfig ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server.
  input ->
  -- | Initial world state. Must be the same across all clients.
  world ->
  -- | A deterministic stepping function (for a single tick). Must be the same
  -- across all clients and the server. Takes:
  --
  -- * a map from PlayerId to current input.
  -- * current game tick.
  -- * previous tick's world state
  --
  -- It is important that this is deterministic else clients' states will
  -- diverge. Beware of floating point non-determinism!
  ( M.Map Core.PlayerId input ->
    Core.Tick ->
    world ->
    world
  ) ->
  IO (Core.Client world input)
runClientWith
  serverHostName
  serverPort
  simNetConditionsMay
  clientConfig
  input0
  world0
  stepOneTick = do
    sendChan <- newChan
    recvChan <- newChan

    -- UDP
    _ <- forkIO $ do
      runUDPClient' serverHostName serverPort $ \sock server -> do
        _ <-
          forkIO $
            writeDatagramContentsAsNetMsg (Just server) fst recvChan sock
        forever $ do
          msg <- readChan sendChan
          NBS.sendAllTo sock (flat msg) server

    Core.runClientWith
      (writeChan sendChan)
      (readChan recvChan)
      simNetConditionsMay
      clientConfig
      input0
      world0
      stepOneTick
 where
  --
  -- Coppied from network-run
  --

  runUDPClient' ::
    HostName -> ServiceName -> (Socket -> SockAddr -> IO a) -> IO a
  runUDPClient' host port client = withSocketsDo $ do
    addr <- resolve Datagram (Just host) port False
    let sockAddr = addrAddress addr
    E.bracket (openSocket addr) close $ \sock -> client sock sockAddr

  resolve :: SocketType -> Maybe HostName -> ServiceName -> Bool -> IO AddrInfo
  resolve socketType mhost port passive =
    head
      <$> getAddrInfo (Just hints) mhost (Just port)
   where
    hints =
      defaultHints
        { addrSocketType = socketType
        , addrFlags = if passive then [AI_PASSIVE] else []
        }

  openSocket :: AddrInfo -> IO Socket
  openSocket addr = do
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    connect sock (addrAddress addr)
    return sock

-- | Run a server for a single game. This will block until the game ends,
-- specifically when all players have disconnected.
runServer ::
  forall input.
  (Eq input, Flat input) =>
  -- | The server's port number.
  ServiceName ->
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
  Int ->
  -- | Initial input for new players. Must be the same across all host/clients.
  input ->
  IO ()
runServer
  serverPort
  tickRate
  input0
  = runServerWith
      serverPort
      Nothing
      (Core.defaultServerConfig tickRate)
      input0

-- | Run a server for a single game. This will block until the game ends,
-- specifically when all players have disconnected.
runServerWith ::
  forall input.
  (Eq input, Flat input) =>
  -- | The server's port number.
  ServiceName ->
  -- | Optional simulation of network conditions. In production this should be
  -- `Nothing`.
  Maybe SimNetConditions ->
  -- | The 'Alpaca.NetCode.Core.defaultServerConfig' works well for most cases.
  Core.ServerConfig ->
  -- | Initial input for new players. Must be the same across all host/clients.
  input ->
  IO ()
runServerWith serverPort tickRate netConfig input0 = do
  sendChan <- newChan
  recvChan <- newChan

  -- UDP
  _ <- forkIO $ do
    runUDPServer Nothing serverPort $ \sock -> do
      _ <- forkIO $ writeDatagramContentsAsNetMsg Nothing id recvChan sock
      forever $ do
        (msg, addr) <- readChan sendChan
        NBS.sendAllTo sock (flat msg) addr

  Core.runServerWith
    (curry (writeChan sendChan))
    (readChan recvChan)
    tickRate
    netConfig
    input0

-- Forever decode messages from the input socket using the given decoding
-- function and writing it to the given chan. Loops forever.
writeDatagramContentsAsNetMsg ::
  forall input a.
  (Flat input) =>
  -- | Just the sender if alwalys receiving from the same address (used in the client case where we only receive from the server)
  (Maybe SockAddr) ->
  -- | Decode the messages
  ((NetMsg input, SockAddr) -> a) ->
  -- | Write decoded msgs to this chan
  Chan a ->
  -- | Read from this socket
  Socket ->
  IO ()
writeDatagramContentsAsNetMsg constSenderMay f chan sock = go
 where
  go = do
    let maxBytes = 4096
    (bs, sender) <- case constSenderMay of
      Nothing -> NBS.recvFrom sock maxBytes
      Just s -> (,s) <$> NBS.recv sock maxBytes
    if BS.length bs == maxBytes
      then
        error $
          "TODO support packets bigger than "
            ++ show maxBytes
            ++ " bytes."
      else
        if BS.length bs == 0
          then debugStrLn "Received 0 bytes from socket. Stopping."
          else do
            case unflat @(NetMsg input) (BSL.fromStrict bs) of
              Left err -> do
                debugStrLn $
                  "Error decoding message: " ++ case err of
                    BadEncoding env errStr ->
                      "BadEncoding " ++ show env ++ "\n" ++ errStr
                    _ -> show err
              Right msg -> writeChan chan (f (msg, sender))
            go
