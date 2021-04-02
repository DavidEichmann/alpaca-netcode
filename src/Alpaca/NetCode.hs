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

-- | This module should be all you need to get started writing multiplayer
-- games. See "NetCode.Advanced" for more advanced usage.
module Alpaca.NetCode
  ( runServer,
    runClient,
    Client,
    clientPlayerId,
    clientSample,
    clientSample',
    clientSetInput,
    clientStop,
    -- ** Types
    Tick (..),
    PlayerId (..),
    HostName,
    ServiceName,
  ) where

import Alpaca.NetCode.Advanced
import qualified Data.Map as M
import Flat (
  Flat,
 )
import Network.Socket (
  HostName,
  ServiceName,
 )

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
  ( M.Map PlayerId input ->
    Tick ->
    world ->
    world
  ) ->
  IO (Client world input)
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
      (defaultClientConfig tickRate)
      input0
      world0
      stepOneTick

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
      (defaultServerConfig tickRate)
      input0