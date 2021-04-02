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

-- | Rollback and replay based game networking
module Alpaca.NetCode.Advanced
  ( -- * Server
    runServerWith,
    module Alpaca.NetCode.Internal.Server,
    -- * Client
    runClientWith,
    module Alpaca.NetCode.Internal.Client,
    -- * Common Types
    SimNetConditions (..),
    Tick (..),
    PlayerId (..),
    NetMsg,
    HostName,
    ServiceName,
  ) where

import Alpaca.NetCode.Internal.Common
import Alpaca.NetCode.Internal.Client
import Alpaca.NetCode.Internal.Server
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
runClientWith ::
  forall world input.
  Flat input =>
  -- | The server's host name or IP address e.g. @"localhost"@.
  HostName ->
  -- | The server's port number e.g. @"8111"@.
  ServiceName ->
  -- | Optional simulation of network conditions. In production this should be
  -- `Nothing`. May differ between clients.
  Maybe SimNetConditions ->
  -- | The 'defaultClientConfig' works well for most cases.
  ClientConfig ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server. See 'Alpaca.NetCode.runClient'.
  input ->
  -- | Initial world state. Must be the same across all clients.
  world ->
  -- | A deterministic stepping function (for a single tick). Must be the same
  -- across all clients and the server. See 'Alpaca.NetCode.runClient'.
  ( M.Map PlayerId input ->
    Tick ->
    world ->
    world
  ) ->
  IO (Client world input)
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

    runClientWith'
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
runServerWith ::
  forall input.
  (Eq input, Flat input) =>
  -- | The server's port number e.g. @"8111"@.
  ServiceName ->
  -- | Optional simulation of network conditions. In production this should be
  -- `Nothing`.
  Maybe SimNetConditions ->
  -- | The 'defaultServerConfig' works well for most cases.
  ServerConfig ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server.
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

  runServerWith'
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
