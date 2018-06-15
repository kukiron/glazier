{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

module Glazier.Command.Exec where

import Control.Applicative
import Control.Lens
import Control.Monad.IO.Unlift
import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Maybe.Extras
import Data.Diverse.Lens
import qualified Data.DList as DL
import Data.Foldable
import Data.Proxy
import Glazier.Command
import qualified UnliftIO.Concurrent as U

-- | Create an executor for a variant in the command type.
-- returns a 'Proxy' to keep track of the the types handled by the executor.
maybeExec :: (Applicative m, AsFacet a c) => (a -> m b) -> c -> MaybeT m (Proxy '[a], b)
maybeExec k c = MaybeT . sequenceA $ (fmap (\b -> (Proxy, b)) . k) <$> preview facet c

-- | Tie an executor with itself to get the final interpreter
fixExec :: Functor m => ((cmd -> m ()) -> cmd -> MaybeT m (Proxy cmds, ())) -> cmd -> m (Proxy cmds, ())
fixExec fexec = let go = (`evalMaybeT` (Proxy, ())) . fexec (fmap snd . go) in go

-- | Use this function to verify at compile time that the given executor will fullfill
-- all the variant types in a command type.
verifyExec ::
    ( AppendUnique '[] ys ~ ys
    , AppendUnique xs ys ~ xs
    , AppendUnique ys xs ~ ys
    , Functor m
    )
    => (cmd -> Which xs) -> (cmd -> m (Proxy ys, b)) -> (cmd -> m b)
verifyExec _ g = fmap snd .  g

-- | Combines executors, keeping track of the combined list of types handled.
orMaybeExec :: (Monad m, a'' ~ Append a a') => MaybeT m (Proxy a, b) -> MaybeT m (Proxy a', b) -> MaybeT m (Proxy a'', b)
orMaybeExec m n = (\b -> (Proxy, b)) <$> ((snd <$> m) <|> (snd <$> n))
infixl 3 `orMaybeExec` -- like <|>

execConcur ::
    MonadUnliftIO m
    => (cmd -> m ())
    -> Concur cmd a
    -> m a
execConcur exec (Concur m) = do
        ea <- execConcur_ exec
        -- Now run the possibly blocking io
        liftIO $ either id pure ea
  where
    execConcur_ exec' = do
        -- get the list of commands to run
        (ma, cs) <- liftIO $ unNewEmptyMVar $ runStateT m mempty
        -- run the batched commands in separate threads
        traverse_ (void . U.forkIO . exec') (DL.toList cs)
        pure ma
