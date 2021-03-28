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
module Server where

-- import           Data.List (foldl')

-- import qualified Data.Set as S
-- import           Data.Time.Clock

-- import qualified Graphics.Gloss.Interface.IO.Game as Gloss

import Common
import Control.Applicative
import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.STM as STM
import Control.Monad (forM_, forever, join, when)
import Data.Coerce (coerce)
import Data.Int (Int32)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import Data.List (dropWhileEnd, foldl')
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Time (getCurrentTime)
import Flat
import FlatOrphans ()
import Network.Run.UDP
import Network.Socket
import Network.Socket.ByteString as NBS
import System.Random (randomRIO)
import Prelude


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


runServer ::
  forall input.
  (Eq input, Flat input) =>
  -- | Ticks per second. Must be the same across all host/clients.
  Int32 ->
  -- | Network options
  NetConfig ->
  -- | Initial input for new players.
  input ->
  IO ()
runServer tickFreq netConfig input0 = playCommon tickFreq $ \tickTime getTime resetTime -> forever $ do
  putStrLn "Waiting for clients"

  -- Authoritative Map from tick and PlayerId to inputs. The inner map is
  -- always complete (e.g. if we have the IntMap for tick i, then it contains
  -- the inputs for *all* known players)
  authInputsTVar :: TVar (IntMap (M.Map PlayerId input)) <- newTVarIO (IM.singleton 0 M.empty)

  -- The next Tick i.e. the first non-frozen tick. All ticks before this
  -- one have been frozen (w.r.t authInputsTVar).
  nextTickTVar :: TVar Tick <- newTVarIO 1

  -- Known players as of now. Nothing means the host (me).
  playersTVar :: TVar (M.Map SockAddr PlayerData) <- newTVarIO M.empty
  -- Known Players (
  --               , last time for which a message was received
  --               )

  -- Next available PlayerId
  nextPlayerIdTVar :: TVar PlayerId <- newTVarIO 0

  -- As the host we're authoritative and always simulating significantly
  -- behind clients. This allows for ample time to receive inputs even
  -- with large ping and jitter. Although the authoritative simulation is
  -- significantly behind clients, we send input hints eagerly, and that
  -- allows clients to make accurately predictions and hence they don't
  -- perceive the lag in authoritative simulation.
  ( sendChan :: NetMsg input -> SockAddr -> STM ()
    , _duplicatedSendChan :: NetMsg input -> SockAddr -> STM ()
    , rcvChan :: STM (NetMsg input, SockAddr)
    ) <- do
    (sendChan', rcvChan') <- setupServer serverPort (simulatedNetConditions netConfig)
    let sendFn msg addr = writeTChan sendChan' (msg, addr)
    return
      ( sendFn
      , sendFn -- TODO reliable (this isn't even duplicated)!
      , readTChan rcvChan'
      )

  -- Main message processing loop
  msgProcessingTID <- forkIO $
    forever $ do
      (msg, sender) <- atomically $ rcvChan

      -- Handle the message
      serverReceiveTimeMay <- case msg of
        Msg_Connected{} -> do
          putStrLn $ "Server received unexpected Msg_Connected from " ++ show sender ++ ". Ignoring."
          return Nothing
        Msg_AuthInput{} -> do
          putStrLn $ "Server received unexpected Msg_AuthInput from " ++ show sender ++ ". Ignoring."
          return Nothing
        Msg_HeartbeatResponse{} -> do
          putStrLn $ "Server received unexpected Msg_HeartbeatResponse from " ++ show sender ++ ". Ignoring."
          return Nothing
        Msg_HintInput{} -> do
          putStrLn $ "Server received unexpected Msg_HintInput from " ++ show sender ++ ". Perhaps you meant to send a Msg_SubmitInput. Ignoring."
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
              sendChan (Msg_Connected pid) sender
              sendChan (Msg_HeartbeatResponse clientSendTime serverReceiveTime) sender
              return $ do
                mapM_ putStrLn debugMsg
                return (Just serverReceiveTime)
        Msg_Heartbeat clientSendTime -> do
          serverReceiveTime <- getTime
          atomically $ do
            isConnected <- isJust . M.lookup sender <$> readTVar playersTVar
            when isConnected $ sendChan (Msg_HeartbeatResponse clientSendTime serverReceiveTime) sender
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
                    let inptsAtTick = fromMaybe M.empty (inputs IM.!? coerce tick)
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
                            (coerce tick)
                            (M.insert playerId input inptsAtTick)
                            inputs

                        return Nothing
          mapM_ putStrLn msgMay
          Just <$> getTime
        Msg_RequestAuthInput ticks -> do
          (inputs, Tick nextTick) <-
            atomically $
              (,) <$> readTVar authInputsTVar
                <*> readTVar nextTickTVar
          forM_ (filter (\t -> 0 <= t && t < Tick nextTick) ticks) $ \(Tick tick) -> do
            let x = inputs IM.! tick
            atomically $
              sendChan
                ( Msg_AuthInput
                    (Tick tick)
                    (toCompactMaps [x])
                    (toCompactMaps [])
                )
                sender
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

  putStrLn "Client connected. Starting game."

  -- Disconnect players after a timeout
  disconnectTID <- forkIO $
    forever $ do
      -- Find next possilbe time to disconnect a player
      oldestMsgRcvTime <- atomically (minimum . fmap lastMesgRcvTime . M.elems <$> readTVar playersTVar)
      let disconnectTime = oldestMsgRcvTime + disconnectTimeout

      -- Wait till the disconnect time (plus a bit to really make sure we pass the threshold)
      t <- getTime
      when (t < disconnectTime) $
        threadDelay (round (((disconnectTime - t) + 0.01) * 1000000))

      -- Kick players as needed
      currentTime <- getTime
      kickedPlayers <- atomically $ do
        players <- readTVar playersTVar
        let (retainedPlayers, kickedPlayers) = M.partition (\PlayerData{..} -> lastMesgRcvTime + disconnectTimeout > currentTime) players
        writeTVar playersTVar retainedPlayers
        return kickedPlayers
      when (not (M.null kickedPlayers)) $ putStrLn $ "Disconnect players due to timeout: " ++ show [pid | PlayerData{playerId = PlayerId pid} <- M.elems kickedPlayers]

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
        let nextAuthTickInputs = authInputs IM.! coerce (nextAuthTick - 1)
        writeTVar authInputsTVar $
          fst $
            foldl'
              ( \(authInputs', prevInputs) currTick ->
                  let -- Fill inputs for the current tick.
                      currInputsRaw = fromMaybe M.empty (IM.lookup (coerce currTick) authInputs)
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
                   in (IM.insert (coerce currTick) currInputs authInputs', currInputs)
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
            (_, _, inputsToSendIntMap') = IM.splitLookup (coerce lastAuthTick) authInputs
            (inputsToSendIntMap, firstHint, _) = IM.splitLookup (coerce nextAuthTick) inputsToSendIntMap'
            inputsToSend = take maxRequestAuthInputs $ IM.elems inputsToSendIntMap
            hintsToSendCount = maxRequestAuthInputs - IM.size inputsToSendIntMap
            hintsToSend =
              fmap (fromMaybe M.empty) $
                dropWhileEnd isNothing $
                  take hintsToSendCount $
                    firstHint :
                      [ authInputs IM.!? coerce hintTick
                      | hintTick <- [succ nextAuthTick ..]
                      ]
        when (not $ null inputsToSend) $
          atomically $ do
            sendChan
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

  putStrLn "No more clients, Stopping game!"

  mapM_ killThread [msgProcessingTID, disconnectTID, simTID]


setupServer ::
  forall input.
  (Flat input) =>
  -- | server port
  Int ->
  -- | Simulated ping, jitter, packet loss (see simulatedNetConditions)
  Maybe (Float, Float, Float) ->
  -- | ( send reliable (order NOT guaranteed)
  --   , recv
  --   )
  -- | ( send reliable (order NOT guaranteed)
  --   , recv
  --   )
  IO (TChan (NetMsg input, SockAddr), TChan (NetMsg input, SockAddr))
setupServer port simNetConMay = do
  sendChan <- newTChanIO
  -- duplicatedSendChan <- newTChanIO
  rcvChan <- newTChanIO

  -- UDP
  _ <- forkIO $ do
    runUDPServer Nothing (show $ port) $ \sock -> do
      _ <- forkIO $ writeDatagramContentsAsNetMsg Nothing id rcvChan sock
      forever $ do
        (msg, addr) <- atomically $ readTChan sendChan
        NBS.sendAllTo sock (flat msg) addr

  -- TCP
  -- _ <- forkIO $
  --   runTCPServer Nothing (show $ port) $ \sock -> do
  --     _ <- forkIO $ writeStreamContentsAsNetMsg id rcvChan sock
  --     onTCPConnect =<< getPeerName sock
  --     forever $ do
  --       (msg, addr) <- atomically $ readTChan duplicatedSendChan
  --       let msgBS = flat msg
  --           len :: StreamMsgHeader
  --           len = fromIntegral $ BS.length msgBS
  --       NBS.sendAllTo sock (flat len <> flat msg) addr

  case simNetConMay of
    -- No simulated network conditions
    Nothing -> return (sendChan, rcvChan)
    -- Simulate network conditions
    Just (ping, jitter, loss) -> do
      simSendChan <- newTChanIO
      -- simduplicatedSendChan <- newTChanIO
      simRcvChan <- newTChanIO
      let simulateNetwork :: TChan a -> TChan a -> IO ThreadId
          simulateNetwork inChan outChan = forkIO $
            forever $ do
              msg <- atomically $ readTChan inChan
              r <- randomRIO (0, 1)
              if r < loss
                then return ()
                else do
                  jitterT <- randomRIO (negate jitter, jitter)
                  let latency = max 0 ((ping / 2) + jitterT)
                  _ <- forkIO $ do
                    threadDelay (round $ latency * 1000000)
                    atomically $ writeTChan outChan msg
                  return ()
      _ <- simulateNetwork simSendChan sendChan
      -- _ <- simulateNetwork simduplicatedSendChan duplicatedSendChan
      _ <- simulateNetwork rcvChan simRcvChan
      return (simSendChan, simRcvChan)