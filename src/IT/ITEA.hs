{-|
Module      : IT.ITEA
Description : Interaction-Transformation Evolutionary Algorithm
Copyright   : (c) Fabricio Olivetti de Franca, 2020
License     : GPL-3
Maintainer  : fabricio.olivetti@gmail.com
Stability   : experimental
Portability : POSIX

Generic implementation of Interaction-Transformation Evolutionary Algorithm
for any instance of IT expression.

To run itea you just need to call 'itea mutFun pop0', 
where 'mutFun' is a mutation function of the type 'Mutation a b',
and 'pop0' is the initial 'Population a b' of solutions.
This function will result in an infinite list of populations, with
the /i/-th element being the population of the /i/-th generation.

This library also provides some generic mutation function builders.
-}
module IT.ITEA where

import IT  
import IT.Algorithms
import IT.Random

import Control.Monad.Extra (iterateM)

import GHC.Conc (numCapabilities)

import Control.Monad.State
import Control.DeepSeq
import Control.Parallel.Strategies
import Data.Maybe
import System.Random
import Data.List (nub)

-- * ITEA

-- | Creates a stream of generations the /i/-th 
-- element corresponds to the population of the /i/-th generation.
itea :: Mutation -> Fitness -> Population -> Rnd [Population]
itea f g p0 = let n = length p0
              in  iterateM (step f g n) p0

-- | Generate an Initial Population at Random
initialPop :: Int                -- ^ maxTerms
           -> Int                -- ^ nPop
           -> Rnd Term       -- ^ random term generator
           -> Fitness          -- ^ fitness function
           -> Rnd Population
initialPop maxTerms nPop rndTerm fit = parRndMap nPop rndIndividual fit (replicate nPop ()) 
  where
    rndExpr = sampleExpr rndTerm

    -- return a random list of random expressions
    rndIndividual () = do n <- sampleRng 1 maxTerms
                          nub <$> rndExpr n
                          

-- | Tournament Selection
--
-- given the concatenation of the previous population
-- and the mutated children, it will return a sampled
-- selection of these combined population with
-- the same size as the original population.
--
tournament :: Population -> Int -> Rnd Population
tournament _ 0 = return []
tournament p n = do p_i <- chooseOne p
                    p'  <- tournament p (n-1)
                    return $ p_i:p'

chooseOne :: Population -> Rnd Solution
chooseOne p = do let n = length p
                 c1 <- sampleTo (n-1)
                 c2 <- sampleTo (n-1)
                 return $ min (p !! c1) (p !! c2)

-- | Perform one iteration of ITEA
step :: Mutation -> Fitness -> Int -> Population -> Rnd Population
step mutFun fitFun nPop pop = do
  children  <- parRndMap nPop (mutFun . _expr) fitFun pop
  if null children
   then tournament pop nPop
   else tournament (pop <> children) nPop
   
-- * Parallel random functions

-- | Runs in parallel the composition of a function that generates random effects with
-- a function that maybe returns a result.
parRndMap :: NFData c => Int -> (a -> Rnd b) -> (b -> Maybe c) -> [a] -> Rnd [c]
parRndMap nPop rndf randFun pop = state stFun
  where
    stFun seed = let seeds         = genNseeds (nPop+1) seed
                     rndpop        = zip seeds pop
                     compFun (s,p) = randFun $ evalState (rndf p) s
                     nSplits       = numberOfSplits nPop
                     pop'          = parMaybeMap nSplits compFun rndpop
                 in  (pop', last seeds)

-- | Calculates the number of splits as twice the number of cores
numberOfSplits :: Int -> Int
numberOfSplits n = n `div` 2*numCapabilities

-- | Generates n random seeds.
genNseeds :: Int -> StdGen -> [StdGen]
genNseeds n = take n . genseeds

-- | Generates an infinite list of random seeds.
genseeds :: StdGen -> [StdGen]
genseeds s = let (s1, s2) = split s
             in  s1 : genseeds s2

-- | Runs a computation that may returns a result in parallel.
parMaybeMap :: NFData b => Int -> (a -> Maybe b) -> [a] -> [b]
parMaybeMap n f pop = catMaybes parmap
  where
    parmap = map f pop `using` parListChunk n rpar
