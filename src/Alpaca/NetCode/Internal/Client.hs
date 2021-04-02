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
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
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
module Alpaca.NetCode.Internal.Client (
  runClientWith',
  ClientConfig (..),
  defaultClientConfig,
  Client,
  clientPlayerId,
  clientSample,
  clientSample',
  clientSetInput,
  clientStop,
) where

import Alpaca.NetCode.Internal.ClockSync
import Alpaca.NetCode.Internal.Common
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM as STM
import Control.Monad
import Data.Int (Int64)
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import qualified Data.Map as M
import Data.Maybe (catMaybes, fromMaybe, isJust)
import qualified Data.Set as S
import Flat


-- | A Client. You'll generally obtain this via 'Alpaca.NetCode.runClient'.
data Client world input = Client
  { -- | The client's @PlayerId@
    clientPlayerId :: PlayerId
  , -- | Sample the world state. First, This will estimate the current tick
    -- based on ping and clock synchronization with the server. Then, the world
    -- state will be rollback and inputs replayed as necessary. This returns:
    --
    -- * New authoritative world states in chronological order since the last
    --   sample time. These world states are the True world states at each tick.
    --   This list will be empty if no new authoritative world states have been
    --   derived since that last call to this sample function. Though it's often
    --   simpler to just use the predicted world state, you can use these
    --   authoritative world states to render output when you're not willing to
    --   miss-predict but are willing to have greater latency. If the client has
    --   been stopped, this will be an empty list.
    --
    -- * The predicted current world state. This extrapolates past the latest
    --   know authoritative world state by assuming no user inputs have changed
    --   (unless otherwise known e.g. our own player's inputs are known). If the
    --   client has been stopped, this will return the last predicted world.
    clientSample' :: IO ([world], world)
  , -- | Set the client's current input.
    clientSetInput :: input -> IO ()
  , -- | Stop the client.
    clientStop :: IO ()
  }


-- | Sample the current world state.
--
-- . First, This will estimate the current tick based on ping and clock
-- synchronization with the server. Then, this extrapolates past the latest know
-- authoritative world state by assuming no user inputs have changed (unless
-- otherwise known e.g. our own player's inputs are known). If the client has
-- been stopped, this will return the last predicted world.
clientSample :: Client world input -> IO world
clientSample client = snd <$> clientSample' client


-- | Configuration options specific to clients.
data ClientConfig = ClientConfig
  { -- | Tick rate (ticks per second). Typically @30@ or @60@. Must be the same
    -- across all clients and the server. Packet rate and hence network bandwidth
    -- will scale linearly with this the tick rate.
    ccTickRate :: Int
  , -- | Add this constant amount of latency (in seconds) to this client's inputs.
    -- A good value is @0.03@ or something between @0@ and @0.1@. May differ
    -- between clients.
    --
    -- Too high of a value and the player will get annoyed at the extra input
    -- latency. On the other hand, a higher value means less miss-predictions of
    -- other clients. In the extreme case, set to something higher than ping,
    -- there will be no miss predictions: all clients will receive inputs before
    -- rendering the corresponding tick.
    ccFixedInputLatency :: Float
  , -- | Maximum number of ticks to predict when sampling. 'defaultClientConfig'
    -- uses @ccTickRate / 2@. If the client is this many ticks behind the current
    -- tick, it will simply stop at an earlier tick. You may want to scale this
    -- value along with the tick rate. May differ between clients.
    ccMaxPredictionTicks :: Int
  , -- | If the client's latest known authoritative world is this many ticks
    -- behind the current tick, no prediction will be done at all when sampling.
    -- 'defaultClientConfig' uses @ccTickRate * 3@. Useful because want to save
    -- CPU cycles for catching up with the server. You may want to scale this
    -- value along with the tick rate. May differ between clients.
    ccResyncThresholdTicks :: Int
  , -- | When submitting inputs to the server, we also send a copy of
    -- @ccSubmitInputDuplication@ many recently submitted inputs in order to
    -- mittigate the effect for dropped packets. 'defaultClientConfig'
    -- uses @15@.
    ccSubmitInputDuplication :: Int
  } deriving (Show, Read, Eq, Ord)


-- | Sensible defaults for @ClientConfig@ based on the tick rate.
defaultClientConfig ::
  -- | Tick rate (ticks per second). Must be the same across all clients and the
  -- server. Packet rate and hence network bandwidth will scale linearly with
  -- this the tick rate.
  Int ->
  ClientConfig
defaultClientConfig tickRate =
  ClientConfig
    { ccTickRate = tickRate
    , ccFixedInputLatency = 0.03
    , ccMaxPredictionTicks = tickRate `div` 2
    , ccResyncThresholdTicks = tickRate * 3
    , ccSubmitInputDuplication = 15
    }


-- | Start a client. This blocks until the initial handshake with the
-- server is finished.
runClientWith' ::
  forall world input.
  Flat input =>
  -- | Function to send messages to the server. The underlying communication
  -- protocol need only guarantee data integrity but is otherwise free to drop
  -- and reorder packets. Typically this is backed by a UDP socket.
  (NetMsg input -> IO ()) ->
  -- | Blocking function to receive messages from the server. Has the same
  -- reliability requirements as the send function.
  (IO (NetMsg input)) ->
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
runClientWith' sendToServer' rcvFromServer' simNetConditionsMay clientConfig input0 world0 stepOneTick = playCommon (ccTickRate clientConfig) $ \tickTime getTime _resetTime -> do
  (sendToServer, rcvFromServer) <-
    simulateNetConditions
      sendToServer'
      rcvFromServer'
      simNetConditionsMay

  -- Authoritative Map from tick and PlayerId to inputs. The inner map is
  -- always complete (e.g. if we have the IntMap for tick i, then it contains
  -- the inputs for *all* known players)
  authInputsTVar :: TVar (IntMap (M.Map PlayerId input)) <- newTVarIO (IM.singleton 0 M.empty)

  -- Tick to authoritative world state.
  authWorldsTVar :: TVar (IntMap world) <- newTVarIO (IM.singleton 0 world0)

  -- Max known auth inputs tick without any prior missing ticks.
  maxAuthTickTVar :: TVar Tick <- newTVarIO 0

  -- This client/host's PlayerId. Initially nothing, then set to Just the
  -- player ID on connection to the server. This is a constant thereafter.
  myPlayerIdTVar <- newTVarIO (Nothing :: Maybe PlayerId)

  -- Non-authoritative Map from tick and PlayerId to inputs. The inner map
  -- is NOT always complete (e.g. if we have the IntMap for tick i, then
  -- it may or may not yet contain all the inputs for *all* known players).
  hintInputsTVar :: TVar (IntMap (M.Map PlayerId input)) <- newTVarIO (IM.singleton 0 M.empty)

  -- Clock Sync
  (estimateServerTickPlusLatencyPlusBufferPlus, recordClockSyncSample, clockAnalytics) <- initializeClockSync tickTime getTime
  let estimateServerTickPlusLatencyPlusBuffer = estimateServerTickPlusLatencyPlusBufferPlus 0

  -- Keep trying to connect to the server.
  heartbeatTid <- forkIO $
    forever $ do
      clientSendTime <- getTime
      isConnected <- isJust <$> atomically (readTVar myPlayerIdTVar)
      sendToServer ((if isConnected then Msg_Heartbeat else Msg_Connect) clientSendTime)
      isClockReady <- isJust <$> clockAnalytics
      threadDelay $
        if isClockReady
          then 500000 -- 0.5 seconds
          else 50000 -- 0.05 seconds

  -- Main message processing loop
  msgLoopTid <- forkIO $
    forever $ do
      msg <- rcvFromServer
      case msg of
        Msg_Connect{} -> debugStrLn "Client received unexpected Msg_Connect from the server. Ignoring."
        Msg_Connected playerId -> do
          join $
            atomically $ do
              playerIdMay <- readTVar myPlayerIdTVar
              case playerIdMay of
                Nothing -> do
                  writeTVar myPlayerIdTVar (Just playerId)
                  return (debugStrLn $ "Connected! " ++ show playerId)
                Just playerId' -> return $ debugStrLn $ "Got Msg_Connected " ++ show playerId' ++ "but already connected (with " ++ show playerId
        Msg_SubmitInput{} -> debugStrLn "Client received unexpected Msg_SubmitInput from the server. Ignoring."
        Msg_Ack{} ->
          debugStrLn "Client received unexpected Msg_Ack from the server. Ignoring."
        Msg_Heartbeat{} ->
          debugStrLn "Client received unexpected Msg_Heartbeat from the server. Ignoring."
        Msg_HeartbeatResponse clientSendTime serverReceiveTime -> do
          -- Record times for ping/clock sync.
          clientReceiveTime <- getTime
          recordClockSyncSample clientSendTime serverReceiveTime clientReceiveTime
        Msg_AuthInput headTick authInputssCompact hintInputssCompact -> do
          let authInputss = fromCompactMaps authInputssCompact
          let hintInputss = fromCompactMaps hintInputssCompact
          resMsgs <- do
            -- Update maxAuthTickTVar if needed and send heartbeat
            ackMsg <- atomically $ do
              maxAuthTick <- readTVar maxAuthTickTVar
              let newestTick = headTick + fromIntegral (length authInputss) - 1
                  maxAuthTick' =
                    if headTick <= maxAuthTick + 1 && maxAuthTick < newestTick
                      then newestTick
                      else maxAuthTick
              writeTVar maxAuthTickTVar maxAuthTick'
              return (Msg_Ack maxAuthTick')
            sendToServer ackMsg

            -- Save new auth inputs
            let newAuthTickHi = headTick + Tick (fromIntegral $ length authInputss)
            resMsg <- forM (zip [headTick ..] authInputss) $ \(tick, inputs) -> do
              atomically $ do
                authInputs <- readTVar authInputsTVar
                -- when (tickInt `mod` 100 == 0) (putStrLn $ "Received auth tick: " ++ show tickInt)
                case authInputs IM.!? fromIntegral tick of
                  Just _ -> return $ Just $ "Received a duplicate Msg_AuthInput for " ++ show tick ++ ". Ignoring."
                  Nothing -> do
                    -- New auth inputs
                    writeTVar authInputsTVar (IM.insert (fromIntegral tick) inputs authInputs)
                    return (Just $ "Got auth-inputs for " ++ show tick)

            -- Save new hint inputs, Excluding my own!
            forM_ (zip [succ newAuthTickHi ..] hintInputss) $ \(tick, newHintinputs) ->
              atomically $ do
                myPlayerIdMay <- readTVar myPlayerIdTVar
                modifyTVar hintInputsTVar $
                  IM.alter
                    ( \case
                        Just oldHintinputs
                          | Just myPlayerId <- myPlayerIdMay ->
                            Just (M.restrictKeys oldHintinputs (S.singleton myPlayerId) <> newHintinputs <> oldHintinputs)
                        _ -> Just newHintinputs
                    )
                    (fromIntegral tick)

            return resMsg
          mapM_ debugStrLn (catMaybes resMsgs)
        Msg_HintInput tick playerId inputs -> do
          res <- atomically $ do
            hintInputs <- readTVar hintInputsTVar
            let hintInputsAtTick = fromMaybe M.empty (hintInputs IM.!? fromIntegral tick)
            writeTVar hintInputsTVar (IM.insert (fromIntegral tick) (M.insert playerId inputs hintInputsAtTick) hintInputs)
            return (Just $ "Got hint-inputs for " ++ show tick)
          mapM_ debugStrLn res

  -- Wait to be connected.
  myPlayerId <- atomically $ do
    myPlayerIdMay <- readTVar myPlayerIdTVar
    maybe retry return myPlayerIdMay

  -- Recently submitted inputs and their tick in reverse chronological order.
  recentSubmittedInputsTVar <- newTVarIO [(Tick 0, input0)]
  -- last returned auth world tick (inclusive) from the sampling function
  lastSampledAuthWorldTickTVar :: TVar Tick <- newTVarIO 0
  -- last returned predicted world from the sampling function
  lastSampledPredictedWorldTVar :: TVar world <- newTVarIO world0
  -- Is the client Stopped?
  stoppedTVar :: TVar Bool <- newTVarIO False

  return $
    Client
      { clientPlayerId = myPlayerId
      , clientSample' = do
          stopped <- atomically $ readTVar stoppedTVar
          if stopped
            then do
              lastPredictedWorld <- atomically $ readTVar lastSampledPredictedWorldTVar
              return ([], lastPredictedWorld)
            else do
              -- TODO we're just resimulating from the last snapshot every
              -- time. We may be able to reuse past simulation data if
              -- snapshot / inputs haven't changed.

              -- Since we are sending inputs for tick
              -- estimateServerTickPlusLatencyPlusBuffer and we want to minimize
              -- perceived input latency, we should target that same tick
              targetTick <- estimateServerTickPlusLatencyPlusBuffer
              (inputs, hintInputs, startTickInt, startWorld) <- atomically $ do
                (startTickInt, startWorld) <-
                  fromMaybe (error $ "No authoritative world found <= " ++ show targetTick) -- We have at least the initial world
                    . IM.lookupLE (fromIntegral targetTick)
                    <$> readTVar authWorldsTVar
                inputs <- readTVar authInputsTVar
                hintInputs <- readTVar hintInputsTVar
                return (inputs, hintInputs, startTickInt, startWorld)
              let startInputs =
                    fromMaybe
                      (error $ "Have auth world but no authoritative inputs at " ++ show startTick) -- We assume that we always have auth inputs on ticks where we have auth worlds.
                      (IM.lookup startTickInt inputs)
                  startTick = Tick (fromIntegral startTickInt)

                  predict ::
                    Int64 -> -- How many ticks of prediction to allow
                    Tick -> -- Some tick i
                    M.Map PlayerId input -> -- inputs at tick i
                    world -> -- world at tick i if simulated
                    Bool -> -- Is the world authoritative?
                    IO world -- world at targetTick (or latest tick if predictionAllowance ran out)
                  predict predictionAllowance tick tickInputs world isWAuth = case compare tick targetTick of
                    LT -> do
                      let tickNext = tick + 1

                          inputsNextAuthMay = inputs IM.!? (fromIntegral tickNext) -- auth input
                          isInputsNextAuth = isJust inputsNextAuthMay
                          isWNextAuth = isWAuth && isInputsNextAuth
                      if isWNextAuth || predictionAllowance > 0
                        then do
                          let inputsNextHintPart = fromMaybe M.empty (hintInputs IM.!? (fromIntegral tickNext)) -- partial hint inputs
                              inputsNextHintFilled = inputsNextHintPart `M.union` tickInputs -- hint input (filled with previous input)
                              inputsNext = fromMaybe inputsNextHintFilled inputsNextAuthMay
                              wNext = stepOneTick inputsNext tickNext world

                              pruneOldAuthWorlds = True
                          -- TODO ^^ in the future we may wan to keep all auth
                          -- worlds to implement a time traveling debugger
                          when isWNextAuth $
                            atomically $ do
                              modifyTVar authWorldsTVar (IM.insert (fromIntegral tickNext) wNext)
                              when pruneOldAuthWorlds $ do
                                -- We keep all new authworlds as we used them in
                                -- `newAuthWorlds` and ultimately return them on
                                -- sample.
                                lastSampledAuthWorldTick <- readTVar lastSampledAuthWorldTickTVar
                                modifyTVar authWorldsTVar (snd . IM.split (fromIntegral lastSampledAuthWorldTick))

                          let predictionAllowance' = if isWNextAuth then predictionAllowance else predictionAllowance - 1
                          predict predictionAllowance' tickNext inputsNext wNext isWNextAuth
                        else return world
                    EQ -> return world
                    GT -> error "Impossible! simulated past target tick!"

              -- If very behind the server, we want to do 0 prediction
              maxAuthTick <- atomically $ readTVar maxAuthTickTVar
              let predictionAllowance =
                    if targetTick - maxAuthTick > Tick (fromIntegral $ ccResyncThresholdTicks clientConfig)
                      then 0
                      else fromIntegral (ccMaxPredictionTicks clientConfig)

              predictedTargetW <- predict predictionAllowance startTick startInputs startWorld True
              atomically $ writeTVar lastSampledPredictedWorldTVar predictedTargetW
              newAuthWorlds :: [world] <- atomically $ do
                lastSampledAuthWorldTick <- readTVar lastSampledAuthWorldTickTVar
                authWorlds <- readTVar authWorldsTVar
                let latestAuthWorldTick = Tick $ fromIntegral $ fst $ IM.findMax authWorlds
                writeTVar lastSampledAuthWorldTickTVar latestAuthWorldTick
                return ((authWorlds IM.!) . fromIntegral <$> [lastSampledAuthWorldTick + 1 .. latestAuthWorldTick])

              return (newAuthWorlds, predictedTargetW)
      , clientSetInput =
          -- TODO We can send (non-auth) inputs p2p!

          -- TODO this mechanism minimizes latency when `targetTick > lastTick` by
          -- sending the input to the server immediately, but when `targetTick <=
          -- lastTick`, then the input will be ghosted!
          \newInput -> do
            stopped <- atomically $ readTVar stoppedTVar
            when (not stopped) $ do
              -- We submit events as soon as we expect the server to be on a future
              -- tick. Else we just store the new input.
              targetTick <- estimateServerTickPlusLatencyPlusBufferPlus (ccFixedInputLatency clientConfig)
              join $
                atomically $ do
                  lastTick <-
                    ( \case
                        [] -> Tick 0
                        (t, _) : _ -> t
                      )
                      <$> readTVar recentSubmittedInputsTVar
                  if targetTick > lastTick
                    then do
                      -- Store our own inputs as a hint so we get 0 latency. This is
                      -- only a hint and not authoritative as it's still possible that
                      -- submitted inputs are dropped or rejected by the server. If
                      -- we've jumped a few ticks forward than we keep we don't attempt
                      -- to submit inputs to "fill in the gap". We assume constant as
                      -- the server and other clients predicted those inputs as constant
                      -- anyway.
                      modifyTVar hintInputsTVar $
                        IM.alter
                          (Just . M.insert myPlayerId newInput . fromMaybe M.empty)
                          (fromIntegral targetTick)

                      modifyTVar recentSubmittedInputsTVar $
                        take (ccSubmitInputDuplication clientConfig)
                          . ((targetTick, newInput) :)
                      inputsToSubmit <- readTVar recentSubmittedInputsTVar
                      return (sendToServer (Msg_SubmitInput inputsToSubmit))
                    else pure (return ())
      , clientStop = do
          stopped <- atomically (readTVar stoppedTVar)
          when (not stopped) $ do
            killThread msgLoopTid
            killThread heartbeatTid
            atomically $ do
              writeTVar stoppedTVar True
      }
