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
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- | Rollback and replay based game networking
module Alpaca.NetCode.Core.Common where

import Control.Concurrent.STM as STM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.List as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Time.Clock
import Data.Word (Word8)
import Flat
import Network.Socket
import Network.Socket.ByteString as NBS
import Prelude


-- Constants

-- Note above, we don't actually step the simulation here. We leave
-- that all up to the draw function. All we need to do is submit
-- inputs once per tick to the server.

serverPort :: Int
serverPort = 8888


-- | Seconds of silence to wait before disconnecting a player
disconnectTimeout :: Float
disconnectTimeout = 5


-- | How many missing inputs to request at a time
maxRequestAuthInputs :: Int
maxRequestAuthInputs = 100


debugStrLn :: String -> IO ()
debugStrLn _ = return ()


-- This can be thought of as how far the authoritative simulation is behind the
-- clients. Making this large does NOT affect latency. It DOES affect how far
-- back clients might need to roll back their simulation. Too small of a buffer
-- time means inputs will tend to be dropped (not made authoritative) because
-- they arrived a bit late. Too high of a buffer time means clients can
-- experience more pronounced popping/corrections due to rollback.
--
-- As dropping inputs is not nice, and we expect high jitter packets to be mor
-- of an exception than a rule, we can set this fairly high.
bufferTime :: Duration
bufferTime = 0.03 -- seconds


type Time = Float -- seconds


type Duration = Float -- seconds


newtype Tick = Tick Int
  deriving stock (Show)
  deriving newtype (Eq, Ord, Num, Enum, Real, Integral, Flat)


instance Monoid Tick where mempty = Tick 0


instance Semigroup Tick where (<>) = (+)


newtype PlayerId = PlayerId {unPlayerId :: Word8}
  deriving stock (Show)
  deriving newtype (Eq, Ord, Num)


deriving via Word8 instance (Flat PlayerId)


data NetConfig = NetConfig
  { -- | Add this latency (in seconds) to all input. Players will experience
    -- this latency even during perfect prediction, but the latency will be
    -- consistent and reduces artifacts because input messages will be received
    -- earlier (at least relative to their intended tick). In the extream case,
    -- if this is set to something higher than ping, there will be no miss
    -- predictions: all clients will receive inputs before rendering their
    -- corresponding tick.
    inputLatency :: Float
  , -- | Simulate:
    -- * Ping (seconds)
    -- * Jitter (seconds)
    -- * Percentage Package loss (0 = no packet loss, 1 = 100% packet loss)
    simulatedNetConditions :: Maybe (Float, Float, Float)
    -- -- | number of times to duplicate unreliable messages (e.g. input messages)
    -- -- to make them more reliable.
    -- msgDuplication :: Int
  }


defaultNetConfig :: NetConfig
defaultNetConfig =
  NetConfig
    { inputLatency = 0.03
    , simulatedNetConditions = Nothing -- Just (0.2, 0, 0.2)
    -- msgDuplication = 5
    }


data Determinism world
  = -- | The step fucntion is deterministic. No need to send the world state,
    -- hence no need for a Binary constraint on world.
    Deterministic
  | NonDeterministic


playCommon ::
  Real a =>
  a ->
  ( Float -> -- seconds per tick
    IO Float -> -- get time
    (UTCTime -> STM ()) -> -- Reset timer to 0 at the given time
    IO b
  ) ->
  IO b
playCommon
  tickFreq
  go =
    do
      let tickTime :: Float
          tickTime = 1 / realToFrac tickFreq

      tick0SysTimTVar <- newTVarIO undefined

      let getTime :: IO Float
          getTime = do
            tick0SysTime <- atomically $ readTVar tick0SysTimTVar
            timeUTC <- getCurrentTime
            return $ realToFrac $ timeUTC `diffUTCTime` tick0SysTime

          resetTime :: UTCTime -> STM ()
          resetTime = writeTVar tick0SysTimTVar

      currentTime <- getCurrentTime
      atomically $ resetTime currentTime

      go tickTime getTime resetTime


data NetMsg input
  = -- Client -> Server
    Msg_Connect
      Float -- Client's local time (used for initial clock sync).
  | -- Server -> Client
    Msg_Connected PlayerId
  | -- | Client -> Server: Regularly sent. Used for clock sync and to acknowledge receiving auth ticks up to a given point.
    Msg_Heartbeat
      Float -- Client's local time (used for clock sync).
  | -- Client -> server
    Msg_Ack
      Tick -- Client's max known auth inputs tick such that there are no missing ticks before it.
  | -- | Server -> Client: Sent in response to Msg_Connect. This indicates the
    -- clients PlayerId
    Msg_HeartbeatResponse
      -- Clock time on the server at Tick 0 is alwyas just 0.
      Float -- Clock time on the client when the connect message was sent.
      Float -- Clock time on the server when the connect message was received.
  | -- | Server -> Client: complete authoritative inputs for a run of ticks
    Msg_AuthInput
      Tick -- Start tick (inclusive)
      (CompactMaps PlayerId input) -- auth ticks starting at the given tick
      (CompactMaps PlayerId input) -- non-auth ticks (hints) starting after the auth ticks
  | -- | A non-authoritative hint for some input.
    Msg_HintInput Tick PlayerId input
  | Msg_SubmitInput Tick input
  | -- | Client -> Server: If (despite any duplication) the client did not receive
    -- auth inputs, the client can request any missing inputs. This case is
    -- detected once we receive any auth inputs for future ticks. By making the
    -- client request missing packets, this avoids a possible DOS attack on the
    -- server compared to an ACK based approach where the client can just never
    -- ACK.
    Msg_RequestAuthInput [Tick]
  deriving stock (Show, Generic)


deriving instance Flat input => Flat (NetMsg input)


newtype CompactMaps key value = CompactMaps [([key], [[value]])]
  deriving stock (Generic, Show)


deriving newtype instance (Flat key, Flat value) => Flat (CompactMaps key value)


-- | Convert a list of maps to a datastructure that is more compact when
-- serialized by flat. This is more compact assuming that many subsequent maps
-- have the same key set.
{-# SPECIALIZE toCompactMaps :: [Map PlayerId input] -> CompactMaps PlayerId input #-}
toCompactMaps :: Eq key => [Map key value] -> CompactMaps key value
toCompactMaps maps =
  CompactMaps
    [ (runKeys, M.elems <$> run)
    | run <- L.groupBy (\a b -> M.keysSet a == M.keysSet b) maps
    , let runKeys = M.keys (head run)
    ]


-- | Inverse of toCompactMaps
{-# SPECIALIZE fromCompactMaps :: CompactMaps PlayerId input -> [Map PlayerId input] #-}
fromCompactMaps :: Eq key => CompactMaps key value -> [Map key value]
fromCompactMaps (CompactMaps runs) =
  [ M.fromAscList (zip keys values)
  | (keys, valuess) <- runs
  , values <- valuess
  ]


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
  TChan a ->
  -- | Read from this socket
  Socket ->
  IO ()
writeDatagramContentsAsNetMsg constSenderMay f chan sock = go
 where
  go = do
    let maxBytes = 4096
    -- putStrLn "."  -- For some reason... adding in these 2 `putStrLn`s makes the thing run! Why? A race condition? A Threading issue?
    (bs, sender) <- case constSenderMay of
      Nothing -> NBS.recvFrom sock maxBytes
      Just s -> (,s) <$> NBS.recv sock maxBytes
    -- putStrLn "."
    if BS.length bs == maxBytes
      then error $ "TODO support packets bigger than " ++ show maxBytes ++ " bytes."
      else
        if BS.length bs == 0
          then putStrLn "Received 0 bytes from socket. Stopping."
          else do
            case unflat @(NetMsg input) (BSL.fromStrict bs) of
              Left err -> do
                putStrLn $
                  "Error decoding message: " ++ case err of
                    BadEncoding env errStr -> "BadEncoding " ++ show env ++ "\n" ++ errStr
                    _ -> show err
              Right msg -> atomically $ writeTChan chan (f (msg, sender))
            go
