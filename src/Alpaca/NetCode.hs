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
-- games. See "Alpaca.NetCode.Advanced" for more advanced usage.
module Alpaca.NetCode
  ( runServer,
    runClient,
    Client,
    clientPlayerId,
    clientSample,
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
-- finished. You must call 'clientSetInput' on the returned client to submit new
-- inputs.
runClient ::
  forall world input.
  Flat input =>
  -- | The server's host name or IP address e.g. @"localhost"@.
  HostName ->
  -- | The server's port number e.g. @"8111"@.
  ServiceName ->
  -- | Tick rate (ticks per second). Typically @30@ or @60@. Must be the same
  -- across all clients and the server. Packet rate and hence network bandwidth
  -- will scale linearly with the tick rate.
  Int ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server.
  --
  -- Note that the client and server do input "prediction" by assuming @input@s
  -- do not change. It is important to design your @input@ type accordingly. For
  -- example, Do NOT store a @Bool@ indicating that a button has been clicked.
  -- Instead, store a @Bool@ indicating if that button is currently held down.
  -- Then, store enough information in the @world@ state to identify a click.
  input ->
  -- | Initial world state. Must be the same across all clients.
  world ->
  -- | A deterministic stepping function (for a single tick). Must be the same
  -- across all clients and the server. Takes:
  --
  -- * a map from PlayerId to current input. You can use the key set as the set
  --   of all connected players.
  -- * current game tick.
  -- * previous tick's world state.
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
  -- | The server's port number e.g. @"8111"@.
  ServiceName ->
  -- | Tick rate (ticks per second). Typically @30@ or @60@. Must be the same
  -- across all clients and the server. Packet rate and hence network bandwidth
  -- will scale linearly with the tick rate.
  Int ->
  -- | Initial input for new players. Must be the same across all clients and
  -- the server.
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