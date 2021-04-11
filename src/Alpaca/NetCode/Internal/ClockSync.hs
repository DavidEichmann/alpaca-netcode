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
module Alpaca.NetCode.Internal.ClockSync where

import Alpaca.NetCode.Internal.Common
import Control.Concurrent.STM
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Prelude


-- TODO make all these constants part of ClientConfig

-- Min/Max Time dilation. This is the maximum speedup of our own clock that
-- we'll allow to catch up to the estimated server clock. Note that the min is
-- greater than 0 meaning that we never stop or reverse time.

minTimeDilation :: Float
minTimeDilation = 0.9


maxTimeDilation :: Float
maxTimeDilation = 1.1


-- Number of ping samples to maintain
pingSamples :: Int
pingSamples = 8


-- Number of timing samples to maintain
timingSamples :: Int
timingSamples = 40


-- Some state for managing clock synchronization
data ClockSync = ClockSync
  -- On the last server time estimate: (client's local time, estimated server's local time)
  { csLastSample :: Maybe (Time, Time)
  , -- Last few samples of point times
    csPingSamples :: [Duration]
  , -- Last few samples of: (server time, estimated corresponding client time)
    -- relative to base.
    csTimingSamples :: [(Time, Time)]
  }


csEstPing :: ClockSync -> Duration
csEstPing (ClockSync{csPingSamples = xs}) = sum xs / (realToFrac $ length xs)


-- | returns (off, drift) sutch that serverTime = (drift * clientTime) + offset
csEstOffsetAndDrift :: ClockSync -> Maybe (Time, Time)
csEstOffsetAndDrift (ClockSync{csTimingSamples = xs})
  | nInt < pingSamples || slopDenom == 0 = Nothing
  -- TODO perhaps it's more efficient to just use https://en.wikipedia.org/wiki/Simple_linear_regression#Fitting_the_regression_line

  | otherwise = Just (offset, slope)
 where
  nInt = length xs
  n = fromIntegral nInt
  avg xs' = sum xs' / n
  avgServer = avg (fst <$> xs)
  avgClient = avg (snd <$> xs)
  slopNumer = sum [(s - avgServer) * (c - avgClient) | (s, c) <- xs]
  slopDenom = sum [(c - avgClient) ^ (2 :: Int64) | (_, c) <- xs]
  slope = slopNumer / slopDenom
  offset = avgServer - (slope * avgClient)


-- | Initialize clock synchronization.
initializeClockSync ::
  -- | Tick time (time per tick in seconds)
  Float ->
  -- | Get the current time from the system in seconds.
  IO Float ->
  -- | Returns:
  --
  -- *  Given some @extraTime@, Estimate the tick on the server when a message
  --    sent at @now + extraTime@ is received by the server plus some extraTime
  --    time.
  --
  -- * Record a clock sync event. Given a heartbeat meassge, this is: client
  --   send time, server receive time, client receive (of the heart beat
  --   response) time)
  --
  -- * analytics returns:
  --
  --   * Ping
  --
  --   * Estimated error from the server clock. This error occurs when we've
  --     committed to some time samples then realize that our measurements are
  --     off. Instead of immediately correcting, we simply dilate time (speeding
  --     up a bit or slowing down a bit) until the "effective" clock is
  --     corrected (see min/maxTimeDilation). On till corrected, our time
  --     estimates differ from what we really think the time is on the server,
  --     and that difference is the "estimated error". Specifically `error =
  --     servertime - effective time`
  IO (Float -> IO Tick, Float -> Float -> Float -> IO (), IO (Maybe (Float, Float)))
initializeClockSync tickTime getTime = do
  clockSyncTVar :: TVar ClockSync <- newTVarIO (ClockSync Nothing [] [])
  let -- Estimate the tick on the server when a message sent at `now + extraTime` is
      -- received by the server plus some extraTime time.
      estimateServerTickPlusLatencyPlusBufferPlus :: Float -> IO Tick
      estimateServerTickPlusLatencyPlusBufferPlus extraTime = do
        clientTime <- getTime
        atomically $ do
          cs <- readTVar clockSyncTVar
          anaMay <- analytics' cs clientTime extraTime
          case anaMay of
            Nothing -> retry
            Just (_estServerTime, dilatedEstServerTime, _ping, newCS) -> do
              writeTVar clockSyncTVar newCS
              return (floor (dilatedEstServerTime / tickTime))

      analytics :: IO (Maybe (Float, Float))
      analytics = do
        clientTime <- getTime
        atomically $ do
          cs <- readTVar clockSyncTVar
          anaMay <- analytics' cs clientTime 0
          case anaMay of
            Nothing -> return Nothing
            Just (estServerTime, dilatedEstServerTime, ping, _newCS) -> do
              return $ Just (ping, estServerTime - dilatedEstServerTime)

      -- (estimated server time, estimated server time clamping time dilation, ping, ClockSync with the new sample point)
      analytics' :: ClockSync -> Time -> Float -> STM (Maybe (Float, Float, Float, ClockSync))
      analytics' cs clientTime extraTime = do
        let offDriftMay = csEstOffsetAndDrift cs
        case offDriftMay of
          Nothing -> return Nothing
          Just (offset, drift) -> do
            let estServerTime = (drift * clientTime) + offset
                clampedEstServerTime = fromMaybe estServerTime $
                  do
                    (lastClientTime, lastEstServerTime) <- csLastSample cs
                    let targetTimeDilation =
                          (estServerTime - lastEstServerTime)
                            / (clientTime - lastClientTime)
                        clampedTimeDilation =
                          min (realToFrac maxTimeDilation) $
                            max (realToFrac minTimeDilation) $
                              targetTimeDilation
                    return $ lastEstServerTime + (clampedTimeDilation * (clientTime - lastClientTime))

            -- For now we're just on local host, so just add a small delay
            -- to the current time to estimate the server time.
            let elapsedTime = clampedEstServerTime
                latency = csEstPing newCS / 2 -- TODO I think adding latency is probably causing some annoying preceived input latency variablility. Rethink this!
                dilatedEstServerTime = (elapsedTime + latency + bufferTime + extraTime)
                newCS = cs{csLastSample = Just (clientTime, clampedEstServerTime)}
                ping = csEstPing newCS
            return $ Just (estServerTime + latency + bufferTime, dilatedEstServerTime, ping, newCS)

      recordClockSyncSample :: Float -> Float -> Float -> IO ()
      recordClockSyncSample clientSendTime serverTime clientReceiveTime = do
        let pingSample = clientReceiveTime - clientSendTime
            latency = pingSample / 2
            timingSample =
              ( serverTime
              , latency + clientSendTime
              )

        _cs' <- atomically $ do
          cs <- readTVar clockSyncTVar
          let cs' =
                ClockSync
                  { csLastSample = csLastSample cs
                  , csPingSamples = take pingSamples (pingSample : csPingSamples cs)
                  , csTimingSamples = take timingSamples (timingSample : csTimingSamples cs)
                  }
          writeTVar clockSyncTVar cs'
          return cs'

        -- putStrLn $ "Ping: " ++ show (csEstPing cs')
        -- forM_ (csEstOffsetAndDrift cs') $ \(off, drift) -> do
        --   putStrLn $ "Offset: " ++ show off
        --   putStrLn $ "Drift: " ++ show drift
        return ()

  return (estimateServerTickPlusLatencyPlusBufferPlus, recordClockSyncSample, analytics)
