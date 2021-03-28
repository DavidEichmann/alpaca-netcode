{-# OPTIONS_GHC -Wno-orphans               #-}

-- | A networked ECS system based on aspec.
module FlatOrphans where

import           Data.Void
import           Flat

instance Flat Void where
