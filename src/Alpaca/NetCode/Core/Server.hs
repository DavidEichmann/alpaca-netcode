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
module Alpaca.NetCode.Core.Server
  ( runServer
  , runServerWith
  , ServerConfig (..)
  , defaultServerConfig
  ) where

import Control.Applicative
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM as STM
import Control.Monad (forM_, forever, join, when)
import Data.Coerce (coerce)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import Data.List (dropWhileEnd, foldl')
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Time (getCurrentTime)
import Flat
import Prelude

import Alpaca.NetCode.Core.Common

-- | Configuration options specific to the server.
data ServerConfig = ServerConfig
  {
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
    scTickRate :: Int
  -- | Seconds of not receiving packets from a client before disconnecting that
  -- client.
  , scClientTimeout :: Float
  }

-- | Sensible defaults for @ServerConfig@ based on the tick rate.
defaultServerConfig ::
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
  Int
  -> ServerConfig
defaultServerConfig tickRate = ServerConfig
  { scTickRate = tickRate
  , scClientTimeout = 5
  }

-- | Run a server for a single game. This will block until the game ends,
-- specifically when all players have disconnected.
runServer ::
  forall input clientAddress.
  ( Eq input
  , Flat input
  , Show clientAddress
  , Ord clientAddress
  ) =>
  -- | Function to send messages to clients. The underlying communication
  -- protocol need only guarantee data integrity but is otherwise free to drop
  -- and reorder packets. Typically this is backed by a UDP socket.
  (NetMsg input -> clientAddress -> IO ()) ->
  -- | Chan to receive messages from clients. Has the same requirements as
  -- the send TChan.
  (IO (NetMsg input, clientAddress)) ->
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
  Int ->
  -- | Initial input for new players.
  input ->
  IO ()
runServer sendToClient'
  recvFromClient'
  tickRate
  input0
  = runServerWith
      sendToClient'
      recvFromClient'
      Nothing
      (defaultServerConfig tickRate)
      input0

-- | Run a server for a single game. This will block until the game ends,
-- specifically when all players have disconnected.
runServerWith ::
  forall input clientAddress.
  ( Eq input
  , Flat input
  , Show clientAddress
  , Ord clientAddress
  ) =>
  -- | Function to send messages to clients. The underlying communication
  -- protocol need only guarantee data integrity but is otherwise free to drop
  -- and reorder packets. Typically this is backed by a UDP socket.
  (NetMsg input -> clientAddress -> IO ()) ->
  -- | Chan to receive messages from clients. Has the same requirements as
  -- the send TChan.
  (IO (NetMsg input, clientAddress)) ->
  -- | Optional simulation of network conditions. In production this should be
  -- `Nothing`. May differ between clients.
  Maybe SimNetConditions ->
  -- | The 'defaultServerConfig' works well for most cases.
  ServerConfig ->
  -- | Initial input for new players.
  input ->
  IO ()
runServerWith sendToClient' recvFromClient' simNetConditionsMay serverConfig input0 = playCommon (scTickRate serverConfig) $ \tickTime getTime resetTime -> forever $ do
  (sendToClient'', recvFromClient) <- simulateNetConditions
    (uncurry sendToClient')
    recvFromClient'
    simNetConditionsMay
  let sendToClient = curry sendToClient''
  debugStrLn "Waiting for clients"

  -- Authoritative Map from tick and PlayerId to inputs. The inner map is
  -- always complete (e.g. if we have the IntMap for tick i, then it contains
  -- the inputs for *all* known players)
  authInputsTVar :: TVar (IntMap (M.Map PlayerId input)) <- newTVarIO (IM.singleton 0 M.empty)

  -- The next Tick i.e. the first non-frozen tick. All ticks before this
  -- one have been frozen (w.r.t authInputsTVar).
  nextTickTVar :: TVar Tick <- newTVarIO 1

  -- Known players as of now. Nothing means the host (me).
  playersTVar :: TVar (M.Map clientAddress PlayerData) <- newTVarIO M.empty
  -- Known Players (
  --               , last time for which a message was received
  --               )

  -- Next available PlayerId
  nextPlayerIdTVar :: TVar PlayerId <- newTVarIO 0

  -- As the host we're authoritative and always simulating significantly
  -- behind clients. This allows for ample time to receive inputs even
  -- with large ping and jitter. Although the authoritative simulation is
  -- significantly behind clients, we send input hints eagerly, and that
  -- allows clients to make accurate predictions and hence they don't
  -- perceive the lag in authoritative inputs.

  -- Main message processing loop
  msgProcessingTID <- forkIO $
    forever $ do
      (msg, sender) <- recvFromClient

      -- Handle the message
      serverReceiveTimeMay <- case msg of
        Msg_Connected{} -> do
          debugStrLn $ "Server received unexpected Msg_Connected from " ++ show sender ++ ". Ignoring."
          return Nothing
        Msg_AuthInput{} -> do
          debugStrLn $ "Server received unexpected Msg_AuthInput from " ++ show sender ++ ". Ignoring."
          return Nothing
        Msg_HeartbeatResponse{} -> do
          debugStrLn $ "Server received unexpected Msg_HeartbeatResponse from " ++ show sender ++ ". Ignoring."
          return Nothing
        Msg_HintInput{} -> do
          debugStrLn $ "Server received unexpected Msg_HintInput from " ++ show sender ++ ". Perhaps you meant to send a Msg_SubmitInput. Ignoring."
          return Nothing
        Msg_Connect clientSendTime -> do
          -- new client connection
          currentTimeUTC <- getCurrentTime
          currentTime <- getTime
          join $
            atomically $ do
              playerMay <- M.lookup sender <$> readTVar playersTVar
              (pid, debugMsg, serverReceiveTime) <- case playerMay of
                Nothing -> do
                  -- New player
                  pid <- readTVar nextPlayerIdTVar
                  writeTVar nextPlayerIdTVar (pid + 1)
                  players <- readTVar playersTVar
                  let isFirstConnection = M.null players
                  -- We only start the game on first connection, so must reset the timer
                  serverReceiveTime <-
                    if isFirstConnection
                      then do
                        resetTime currentTimeUTC
                        return 0
                      else return currentTime
                  writeTVar playersTVar (M.insert sender (PlayerData{playerId = pid, maxAuthTick = 0, lastMesgRcvTime = serverReceiveTime}) players)
                  return (pid, Just ("Connected " ++ show sender ++ " as " ++ show pid), serverReceiveTime)
                Just PlayerData{..} -> do
                  -- Existing player
                  return (playerId, Nothing, currentTime)
              return $ do
                sendToClient (Msg_Connected pid) sender
                sendToClient (Msg_HeartbeatResponse clientSendTime serverReceiveTime) sender
                mapM_ debugStrLn debugMsg
                return (Just serverReceiveTime)
        Msg_Heartbeat clientSendTime -> do
          serverReceiveTime <- getTime
          isConnected <- atomically (isJust . M.lookup sender <$> readTVar playersTVar)
          when isConnected $ sendToClient (Msg_HeartbeatResponse clientSendTime serverReceiveTime) sender
          return (Just serverReceiveTime)
        Msg_Ack clientMaxAuthTick -> do
          atomically $ modifyTVar playersTVar (M.update (\pd -> Just $ pd{maxAuthTick = clientMaxAuthTick}) sender)
          Just <$> getTime
        Msg_SubmitInput tick input -> do
          msgMay <- atomically $ do
            -- Check that the sender is connected.
            playerMay <- M.lookup sender <$> readTVar playersTVar
            case playerMay of
              Nothing -> return $ Just $ "Got Msg_SubmitInput from client that is not yet connected " ++ show sender
              Just PlayerData{..} -> do
                -- Check that the tick time has not already been simulated.
                nextTick <- readTVar nextTickTVar
                -- TODO upper bound on allowed tick time.
                if tick < nextTick
                  then
                    return $
                      Just $
                        "Late Msg_Input from " ++ show playerId
                          ++ " for "
                          ++ show tick
                          ++ " but already simulated up to "
                          ++ show (nextTick - 1)
                          ++ ". Ignoring."
                  else do
                    inputs <- readTVar authInputsTVar
                    let inptsAtTick = fromMaybe M.empty (inputs IM.!? fromIntegral tick)
                    case inptsAtTick M.!? playerId of
                      Just existingInput
                        -- Duplicate message. Silently ignore
                        | existingInput == input -> return Nothing
                        -- Different input for the same tick!
                        | otherwise ->
                          return $
                            Just $
                              "Received inputs from " ++ show playerId ++ " for " ++ show tick
                                ++ " but already have inputs for that time with a DIFFERENT value! Ignoring."
                      -- First time we're hearing of this input. Store it.
                      Nothing -> do
                        writeTVar authInputsTVar $
                          IM.insert
                            (fromIntegral tick)
                            (M.insert playerId input inptsAtTick)
                            inputs

                        return Nothing
          mapM_ debugStrLn msgMay
          Just <$> getTime

      -- set receive time for players
      forM_ serverReceiveTimeMay $ \serverReceiveTime ->
        atomically $
          modifyTVar
            playersTVar
            ( M.update
                (\player -> Just player{lastMesgRcvTime = serverReceiveTime})
                sender
            )

  -- Wait for a connection
  atomically $ do
    players <- readTVar playersTVar
    STM.check $ not $ M.null players

  debugStrLn "Client connected. Starting game."

  -- Disconnect players after a timeout
  disconnectTID <- forkIO $
    forever $ do
      -- Find next possilbe time to disconnect a player
      oldestMsgRcvTime <- atomically (minimum . fmap lastMesgRcvTime . M.elems <$> readTVar playersTVar)
      let disconnectTime = oldestMsgRcvTime + scClientTimeout serverConfig

      -- Wait till the disconnect time (plus a bit to really make sure we pass the threshold)
      t <- getTime
      when (t < disconnectTime) $
        threadDelay (round (((disconnectTime - t) + 0.01) * 1000000))

      -- Kick players as needed
      currentTime <- getTime
      kickedPlayers <- atomically $ do
        players <- readTVar playersTVar
        let (retainedPlayers, kickedPlayers) = M.partition (\PlayerData{..} -> lastMesgRcvTime + scClientTimeout serverConfig > currentTime) players
        writeTVar playersTVar retainedPlayers
        return kickedPlayers
      when (not (M.null kickedPlayers)) $ debugStrLn $ "Disconnect players due to timeout: " ++ show [pid | PlayerData{playerId = PlayerId pid} <- M.elems kickedPlayers]

  -- Main "simulation" loop
  simTID <- forkIO $
    forever $ do
      -- Calculate target tick according to current time
      currTime <- getTime
      let targetTick = floor $ currTime / tickTime

      -- Fill auth inputs
      atomically $ do
        nextAuthTick <- readTVar nextTickTVar

        -- Freeze ticks.
        writeTVar nextTickTVar (targetTick + 1)

        -- Advance auth inputs up to target tick.
        knownPlayers <- readTVar playersTVar
        authInputs <- readTVar authInputsTVar
        let nextAuthTickInputs = authInputs IM.! fromIntegral (nextAuthTick - 1)
        writeTVar authInputsTVar $
          fst $
            foldl'
              ( \(authInputs', prevInputs) currTick ->
                  let -- Fill inputs for the current tick.
                      currInputsRaw = fromMaybe M.empty (IM.lookup (fromIntegral currTick) authInputs)
                      currInputs =
                        M.fromList
                          [ ( pidInt
                            , fromMaybe
                                input0
                                ( currInputsRaw M.!? pid
                                    <|> prevInputs M.!? pid
                                )
                            )
                          | pid <- playerId <$> M.elems knownPlayers
                          , let pidInt = coerce pid
                          ]
                   in (IM.insert (fromIntegral currTick) currInputs authInputs', currInputs)
              )
              (authInputs, nextAuthTickInputs)
              [nextAuthTick .. targetTick]

      -- broadcast some auth inputs
      knownPlayers <- atomically $ readTVar playersTVar
      (authInputs, nextAuthTick) <- atomically $ do
        authInputs <- readTVar authInputsTVar
        nextAuthTick <- readTVar nextTickTVar
        return (authInputs, nextAuthTick)
      forM_ (M.assocs knownPlayers) $ \(sock, playerData) -> do
        let lastAuthTick = maxAuthTick playerData
            (_, _, inputsToSendIntMap') = IM.splitLookup (fromIntegral lastAuthTick) authInputs
            (inputsToSendIntMap, firstHint, _) = IM.splitLookup (fromIntegral nextAuthTick) inputsToSendIntMap'
            inputsToSend = take maxRequestAuthInputs $ IM.elems inputsToSendIntMap
            hintsToSendCount = maxRequestAuthInputs - IM.size inputsToSendIntMap
            hintsToSend =
              fmap (fromMaybe M.empty) $
                dropWhileEnd isNothing $
                  take hintsToSendCount $
                    firstHint :
                      [ authInputs IM.!? fromIntegral hintTick
                      | hintTick <- [succ nextAuthTick ..]
                      ]
        when (not $ null inputsToSend) $
          sendToClient
            ( Msg_AuthInput
                (lastAuthTick + 1)
                (toCompactMaps inputsToSend)
                (toCompactMaps hintsToSend)
            )
            sock

      -- Sleep thread till the next tick.
      currTime' <- getTime
      let nextTick = targetTick + 1
          nextTickTime = fromIntegral nextTick * tickTime
          timeTillNextTick = nextTickTime - currTime'
      threadDelay $ round $ 1000000 * timeTillNextTick

  -- Wait till all players quit
  atomically $ do
    players <- readTVar playersTVar
    STM.check $ M.null players

  debugStrLn "No more clients, Stopping game!"

  mapM_ killThread [msgProcessingTID, disconnectTID, simTID]

-- | Per player info stored by the server
data PlayerData = PlayerData
  { -- | last tick for which auth inputs were sent from the server
    playerId :: PlayerId
  , -- | Client's max known auth inputs tick such that there are no missing
    -- ticks before it.
    maxAuthTick :: Tick
  , -- | Last server time at which a message was received from this player.
    lastMesgRcvTime :: Float
  }
