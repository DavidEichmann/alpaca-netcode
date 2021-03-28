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
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Append only datastructures that provide blocking
module AppendParallel where

import Control.Concurrent.MVar
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)

newtype APRef a = APRef (IORef (Either (MVar a) a))

-- | Try to write to an APRef. If already written, then this is a noop and False
-- is returned. True if successfully written
writeAPRef :: APRef a -> a -> IO Bool
writeAPRef (APRef ioref) a = do
  mvarMay <- atomicModifyIORef ioref $ \case
    Left mvar -> (Right a, Just mvar)
    old -> (old, Nothing)
  case mvarMay of
    Nothing -> return False
    Just mvar -> do
      putMVar mvar a
      return True

-- | This is "safe" in the sense that this will always return the same result,
-- but unsafe in the sense that it will deadlock if the current thread is
-- responsible for writing to this APRef (and has not yet done so on forcing the
-- result of this call).
readAPRef :: APRef a -> a
readAPRef = unsafePerformIO . readAPRefIO

readAPRefIO :: APRef a -> IO a
readAPRefIO (APRef ioref) = do
  x <- readIORef ioref
  case x of
    Left mvar -> readMVar mvar
    Right a -> return a

tryReadAPRefIO :: APRef a -> IO (Maybe a)
tryReadAPRefIO (APRef ioref) = do
  x <- readIORef ioref
  return $ case x of
    Left _ -> Nothing
    Right a -> Just a
