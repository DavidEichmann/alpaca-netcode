{-# LANGUAGE ScopedTypeVariables #-}

import Test.Tasty
import Test.Tasty.HUnit
import Control.Concurrent
import Control.Monad (forever, when)
import Data.Bits
import Data.Map (Map)
import Data.Maybe (isNothing)
import qualified Data.Map as M
import Data.Int (Int64)
import System.Random (randomIO)
import System.Timeout (timeout)
import Alpaca.NetCode
  ( PlayerId(..)
  , Tick(..)
  , Client(..)
  , SimNetConditions(..)
  , ServerConfig(..)
  , ClientConfig(..)
  , defaultServerConfig
  , defaultClientConfig, clientSample
  )
import qualified Alpaca.NetCode as NC
import qualified Alpaca.NetCode.Core as Core
import Data.Maybe (fromMaybe)
import Data.List (foldl')

main :: IO ()
main = defaultMain $ testGroup "alpaca-netcode" $ let
  tickRate = 1000
  tickRate32 = fromIntegral 1000

  initialInput :: Int64
  initialInput = 123456789

  inputLatency :: Float
  inputLatency = 0.1

  -- Step of the world does a simple hashes all the inputs.
  stepWorld :: Map PlayerId Int64 -> Tick -> (Int64, Int64) -> (Int64, Int64)
  stepWorld playerInputs (Tick t) (_numPlayersOld, hash) =
    ( fromIntegral $ M.size playerInputs
    , foldl'
      (\hash' x -> (shiftL hash' 1) `xor` x)
      (shiftL hash 1 `xor` t)
      (concat [[fromIntegral i, j] | (PlayerId i, j) <- M.toList playerInputs])
    )

  -- (number of players on this tick, hash over past states/inputs)
  initialWorld :: (Int64, Int64)
  initialWorld = (0, 12345654321)

  simulateClient :: (Int64 -> IO ()) -> IO ThreadId
  simulateClient setInput = forkIO $ forever $ do
    threadDelay (1000000 `div` tickRate)
    setInput =<< randomIO

  test ::
    ( Maybe SimNetConditions
        -> ServerConfig
        -> Int64
        -> IO ()
    )
    -> (Maybe SimNetConditions
          -> ClientConfig
          -> Int64
          -> (Int64, Int64)
          -> (Map PlayerId Int64 -> Tick -> (Int64, Int64) -> (Int64, Int64)) -> IO (Client (Int64, Int64) Int64)
       )
    -> (Maybe SimNetConditions
          -> ClientConfig
          -> Int64
          -> (Int64, Int64)
          -> (Map PlayerId Int64 -> Tick -> (Int64, Int64) -> (Int64, Int64)) -> IO (Client (Int64, Int64) Int64)
       )
    -> IO ()
  test runServerWith' runClient0With' runClient1With' = do
        x <- timeout (15 * 1000000) $ do
          -- Run a server
          tidServer <- forkIO $ runServerWith'
            Nothing
            (defaultServerConfig tickRate32)
            initialInput

          -- A client with Perfect network conditions
          client0 <- runClient0With'
            Nothing
            (defaultClientConfig tickRate32)
            initialInput
            initialWorld
            stepWorld
          tid0 <- simulateClient (clientSetInput client0)

          -- A client with very poor network conditions
          client1 <- runClient1With'
            (Just (SimNetConditions 0.2 0.1 0.5))
            (defaultClientConfig tickRate32)
            initialInput
            initialWorld
            stepWorld
          tid1 <- simulateClient (clientSetInput client1)

          -- Let the game play for a bit
          threadDelay (4 * 1000000)

          -- Collect auth worlds from both clients
          let n = 2000
          auths0 <- take n . fst <$> clientSample' client0
          auths1 <- take n . fst <$> clientSample' client1

          length auths0 >= n @? "Expected at least " ++ show n ++ " auth worlds but client 0 got " ++ show (length auths0)
          length auths1 >= n @? "Expected at least " ++ show n ++ " auth worlds but client 1 got " ++ show (length auths1)

          (auths0 == auths1) @? "Auth worlds do not match between clients"

          let k = 100
          length (filter ((>0) . fst) auths0) > k @? "Expected at least " ++ show k ++ " tick with more that 0 players"

          killThread tidServer
          clientStop client0
          killThread tid0
          clientStop client1
          killThread tid1

          return ()
        when (isNothing x) (assertFailure "Timeout!")
  in
    [ testCase "Core" $ do
        -- Use `Chan` to communicate
        toServer <- newChan
        toClient0 <- newChan
        toClient1 <- newChan

        test
          (Core.runServerWith
            (\msg (client :: Int64) -> case client of
              0 -> writeChan toClient0 msg
              1 -> writeChan toClient1 msg
              _ -> error $ "Test error! unknown client: " ++ show client
            )
            (readChan toServer)
          )
          ( Core.runClientWith
              (\msg -> writeChan toServer (msg, 0))
              (readChan toClient0)
          )
          (Core.runClientWith
            (\msg -> writeChan toServer (msg, 1))
            (readChan toClient1)
          )
    , testCase "UDP [NOCI]" $ do
        let port = "8888"
        test
          (NC.runServerWith port)
          (NC.runClientWith "localhost" port)
          (NC.runClientWith "localhost" port)
    , testCase "clientStop" $ do
        toServer <- newChan
        toClient <- newChan

        -- Run a server
        tidServer <- forkIO $ Core.runServerWith
          (\msg 0 -> writeChan toClient msg)
          (readChan toServer)
          Nothing
          (defaultServerConfig tickRate32)
          initialInput

        -- A client with Perfect network conditions
        client <- Core.runClientWith
          (\msg -> writeChan toServer (msg, 0))
          (readChan toClient)
          Nothing
          (defaultClientConfig tickRate32)
          initialInput
          initialWorld
          stepWorld
        tidClient <- simulateClient (clientSetInput client)

        threadDelay (2 * 1000000)
        clientStop client
        w <- clientSample client
        threadDelay (1 * 1000000)
        (authWs', w') <- clientSample' client
        assertEqual
          "Sample after clientStop should return the last sampled world"
          w w'
        assertEqual
          "Sample after clientStop should return no new auth worlds"
          authWs' []

        threadDelay (1 * 1000000)
        clientStop client
        (authWs'', w'') <- clientSample' client
        assertEqual
          "Sample after SECOND clientStop should return the last sampled world"
          w w''
        assertEqual
          "Sample after clientStop should return no new auth worlds"
          authWs'' []

        killThread tidServer
        killThread tidClient

    ]