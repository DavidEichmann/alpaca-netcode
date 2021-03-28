{-# LANGUAGE ScopedTypeVariables #-}

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck as QC
  ( NonZero (NonZero),
    counterexample,
    testProperty,
  )

main :: IO ()
main = putStrLn "Hello Test!"