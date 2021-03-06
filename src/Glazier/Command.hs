{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

module Glazier.Command
    ( MonadCodify(..)
    , codifies'
    , codify
    , codify'
    , MonadCommand
    , command
    , command'
    , command_
    , commands
    , instruct
    , instructs
    , exec
    , exec'
    , exec_
    , eval
    , eval'
    , sequentially
    , dispatch
    , dispatch_
    , concurringly
    , concurringly_
    , AsConcur
    , Concur(..)
    , NewEmptyMVar -- Hiding constructor
    , unNewEmptyMVar
    ) where

import Control.Applicative
import Control.Concurrent
import Control.Lens
import Control.Monad.Cont
import Control.Monad.Delegate
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Cont
import Control.Monad.Trans.Except
import Control.Monad.Trans.Identity
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.State.Lazy as Lazy
import Control.Monad.Trans.State.Strict as Strict
import Data.Diverse.Lens
import qualified Data.DList as DL
import GHC.Generics

#if MIN_VERSION_base(4,9,0) && !MIN_VERSION_base(4,10,0)
import Data.Semigroup
#endif

----------------------------------------------
-- Command utilties
----------------------------------------------

-- | Converts a handler that result in monad transformer stack with a 'State' of list of commands
-- to a handler that result in a list of commands, using the current monad context,
-- by running the State of comands with mempty like Writer.
class Monad m => MonadCodify cmd m | m -> cmd where
    codifies :: (a -> m ()) -> m (a -> [cmd])

-- | Variation of 'codifies' to transform the monad stack instead of a handler.
codifies' :: (MonadCodify cmd m) => m () -> m [cmd]
codifies' m = do
    f <- codifies (const m)
    pure (f ())

-- | Variation of 'codifies' to output a handler that result in a single command
codify :: (AsFacet [cmd] cmd, MonadCodify cmd m) => (a -> m ()) -> m (a -> cmd)
codify f = (commands .) <$> codifies f

-- | Variation of 'codify' to transform the monad stack instead of a handler.
codify' :: (AsFacet [cmd] cmd, MonadCodify cmd m) => m () -> m cmd
codify' m = do
    f <- codify (const m)
    pure (f ())

-- | Instance that does real work by running the State of commands with mempty.
instance MonadCodify cmd (Strict.State (DL.DList cmd)) where
    codifies f = pure $ \a -> DL.toList . (`Strict.execState` mempty) $ f a

-- | Instance that does real work by running the 'State' of commands with mempty.
instance MonadCodify cmd (Lazy.State (DL.DList cmd)) where
    codifies f = pure $ \a -> DL.toList . (`Lazy.execState` mempty) $ f a

-- | Passthrough instance
instance MonadCodify cmd m => MonadCodify cmd (IdentityT m) where
    codifies f = lift . codifies $ runIdentityT . f

-- | Passthrough instance
instance MonadCodify cmd m => MonadCodify cmd (ContT () m) where
    codifies f = lift . codifies $ evalContT . f

-- | Passthrough instance, using the Reader context
instance MonadCodify cmd m => MonadCodify cmd (ReaderT r m) where
    codifies f = do
        r <- ask
        lift . codifies $ (`runReaderT` r) . f

-- | Passthrough instance, ignoring that the handler result might be Nothing.
instance MonadCodify cmd m => MonadCodify cmd (MaybeT m) where
    codifies f = lift . codifies $ void . runMaybeT . f

-- | Passthrough instance which requires the inner monad to be a 'MonadDelegate'.
-- This means that the @Left e@ case can be handled by the provided delegate.
instance (MonadDelegate () m, MonadCodify cmd m) => MonadCodify cmd (ExceptT e m) where
    codifies f = ExceptT $ delegate $ \kec -> do
        let g a = do
                e <- runExceptT $ f a
                case e of
                    Left e' -> kec (Left e')
                    Right _ -> pure ()
        g' <- codifies g
        kec (Right g')

type MonadCommand cmd m =
    ( MonadState (DL.DList cmd) m
    , MonadDelegate () m
    , MonadCodify cmd m
    , AsFacet [cmd] cmd
    )

-- | convert a request type to a command type.
-- This is used for commands that doesn't have a continuation.
-- Ie. commands that doesn't "returns" a value from running an effect.
-- Use 'command'' for commands that require a continuation ("returns" a value).
command :: (AsFacet c cmd) => c -> cmd
command = review facet

-- | A variation of 'command' for commands with a type variable @cmd@,
-- which is usually commands that are containers of command,
-- or commands that require a continuation
-- Eg. commands that "returns" a value from running an effect.
command' :: (AsFacet (c cmd) cmd) => c cmd -> cmd
command' = review facet

-- | This helps allow executors of commands of a results only need to execute the type @c cmd@,
-- ie, when the command result in the next @cmd@.
-- This function is useful to fmap a command with a result of unit
--  to to a command with a result @cmd@ type.
command_ :: (AsFacet [cmd] cmd) => () -> cmd
command_ = command' . const []

-- | Convert a list of commands to a command. This implementation avoids nesting
-- for lists of a single command.
commands :: (AsFacet [cmd] cmd) => [cmd] -> cmd
commands [x] = x
commands xs = command' xs

-- | Add a command to the list of commands for this MonadState.
-- I basically want a Writer monad, but I'm using a State monad
-- because but I also want to use it inside a ContT which only has an instance of MonadState.
instruct :: (MonadState (DL.DList cmd) m) => cmd -> m ()
instruct c = id %= (`DL.snoc` c)

-- | Adds a list of commands to the list of commands for this MonadState.
instructs :: (MonadState (DL.DList cmd) m) => [cmd] -> m ()
instructs cs = id %= (<> DL.fromList cs)

-- | @'exec' = 'instruct' . 'command'@
exec :: (MonadState (DL.DList cmd) m, AsFacet c cmd) => c -> m ()
exec = instruct . command

-- | @'exec'' = 'instruct' . 'command''@
exec' :: (MonadState (DL.DList cmd) m, AsFacet (c cmd) cmd) => c cmd -> m ()
exec' = instruct . command'

-- | @'exec'' = 'instruct' . 'command''@
exec_ :: (Functor c, MonadState (DL.DList cmd) m, AsFacet [cmd] cmd, AsFacet (c cmd) cmd)
    => c () -> m ()
exec_ = instruct . command' . fmap command_

-- | This converts a monadic function that requires a handler for @a@ into
-- a monad that fires the @a@ so that the do notation can be used to compose the handler.
-- 'eval_' is used inside an 'evalContT' block or 'concurringly'.
-- If it is inside a 'evalContT' then the command is evaluated sequentially.
-- If it is inside a 'concurringly', then the command is evaluated concurrently
-- with other commands.
--
-- @
-- If tne input function purely returns a command, you can use:
-- eval_ . (exec' .) :: ((a -> cmd) -> c cmd) -> m a
--
-- If tne input function monnadic returns a command, you can use:
-- eval_ . ((>>= exec') .) :: ((a -> cmd) -> m (c cmd)) -> m a
-- @
eval_ ::
    ( MonadDelegate () m
    , MonadCodify cmd m
    , AsFacet [cmd] cmd
    )
    => ((a -> cmd) -> m ()) -> m a
eval_ m = delegate $ \k -> do
    f <- codify k
    m f

eval' ::
    ( MonadCommand cmd m
    , AsFacet [cmd] cmd
    , AsFacet (c cmd) cmd
    )
    => ((a -> cmd) -> c cmd) -> m a
eval' k = eval_ $ exec' . k

eval ::
    ( MonadCommand cmd m
    , AsFacet [cmd] cmd
    , AsFacet c cmd
    )
    => ((a -> cmd) -> c) -> m a
eval k = eval_ $ exec . k

-- | Adds a 'MonadCont' constraint. It is redundant but rules out
-- using 'Concur' at the bottom of the transformer stack.
-- 'sequentially' is used for operations that MUST run sequentially, not concurrently.
-- Eg. when the overhead of using 'Concur' 'MVar' is not worth it, or
-- when data dependencies are not explicitly specified by monadic binds,
-- Eg. A command to update mutable variable must exact before
-- a command that reads from the mutable variable.
-- In this case, the reference to the variable doesn't change, so the
-- data dependency is not explicit.
sequentially :: MonadCont m => m a -> m a
sequentially = id

-- | Retrieves the result of a functor command.
dispatch ::
    ( AsFacet (c cmd) cmd
    , MonadCommand cmd m
    , Functor c
    ) => c a -> m a
dispatch c = delegate $ \fire -> do
    fire' <- codify fire
    exec' $ fire' <$> c

-- | Retrieves the result of a functor command.
-- A simpler variation of 'dispatch' that only requires a @MonadState (DL.DList cmd) m@
dispatch_ ::
    ( AsFacet (c cmd) cmd
    , AsFacet [cmd] cmd
    , MonadState (DL.DList cmd) m
    , Functor c
    ) => c () -> m ()
dispatch_ = exec' . fmap command_

----------------------------------------------
-- Batch independant commands
----------------------------------------------

type AsConcur cmd = (AsFacet [cmd] cmd, AsFacet (Concur cmd cmd) cmd)

-- | This monad is intended to be used with @ApplicativeDo@ to allow do notation
-- for composing commands that can be run concurrently.
-- The 'Applicative' instance can merge multiple commands into the internal state of @DList c@.
-- The 'Monad' instance creates a 'ConcurCmd' command before continuing the bind.
newtype Concur cmd a = Concur
    -- The base IO doesn't block (only does newEmptyMVar), but may return an IO that blocks.
    -- The return is @Either (IO a) a@ where 'Left' is used for blocking IO
    -- and 'Right' is used for nonblocking pure values.
    -- This distinction prevents nested layers of MVar for pure monadic binds.
    -- See the instance of 'Monad' for 'Concur'.
    -- Once a blocking IO is returned, then all subsequent binds require another nested MVar.
    -- So it is more efficient to groups of pure binds first before binding with blocking code.
    { runConcur :: Strict.StateT (DL.DList cmd) NewEmptyMVar (Either (IO a) a)
    } deriving (Generic)

instance Show (Concur cmd a) where
    showsPrec _ _ = showString "Concur"

-- | NB. Don't export NewEmptyMVar constructor to guarantee
-- that that it only contains non-blocking 'newEmptyMVar' IO.
newtype NewEmptyMVar a = NewEmptyMVar (IO a)
    deriving (Functor, Applicative, Monad)

unNewEmptyMVar :: NewEmptyMVar a -> IO a
unNewEmptyMVar (NewEmptyMVar m) = m

-- This is a monad morphism that can be used to 'Control.Monad.Morph.hoist' transformer stacks on @Concur cmd a@
concurringly ::
    ( MonadCommand cmd m
    , AsConcur cmd
    -- , MonadCont m
    ) => Concur cmd a -> m a
concurringly = dispatch

-- | This is a monad morphism that can be used to 'Control.Monad.Morph.hoist' transformer stacks on @Concur cmd ()@
-- A simpler variation of 'concurringly' that only requires a @MonadState (DL.DList cmd) m@
concurringly_ :: (MonadState (DL.DList cmd) m, AsConcur cmd) => Concur cmd () -> m ()
concurringly_ = dispatch_

instance (AsConcur cmd) => MonadState (DL.DList cmd) (Concur cmd) where
    state m = Concur $ Right <$> Strict.state m

instance Functor (Concur cmd) where
    fmap f (Concur m) = Concur $ (either (Left . fmap f) (Right . f)) <$> m

-- | Applicative instand allows building up list of commands without blocking
instance Applicative (Concur cmd) where
    pure = Concur . pure . pure
    (Concur f) <*> (Concur a) = Concur $ liftA2 go f a
      where
        go :: Either (IO (a -> b)) (a -> b)
             -> Either (IO a) a
             -> Either (IO b) b
        go g b = case (g, b) of
            (Left g', Left b') -> Left (g' <*> b')
            (Left g', Right b') -> Left (($b') <$> g')
            (Right g', Left b') -> Left (g' <$> b')
            (Right g', Right b') -> Right (g' b')

-- Monad instance can't build commands without blocking.
instance (AsConcur cmd) => Monad (Concur cmd) where
    (Concur m) >>= k = Concur $ do
        m' <- m -- get the blocking io action while updating the state
        case m' of
            -- pure value, no blocking required, avoid using MVar.
            Right a -> runConcur $ k a
            -- blocking io, must use MVar
            Left ma -> do
                v <- lift $ NewEmptyMVar newEmptyMVar
                exec' $ flip fmap (Concur @cmd $ pure (Left ma))
                    (\a -> command' $ flip fmap (k a)
                        (\b -> command' $ command_ <$> (Concur @cmd $ pure $ Left $ putMVar v b)))
                pure $ Left $ takeMVar v

instance AsConcur cmd => MonadCodify cmd (Concur cmd) where
    codifies f = pure $ pure . command' . fmap command_ . f

-- | This instance makes usages of 'sequel' concurrent when used
-- insdie a 'concurringly' or 'concurringly_' block.
-- Converts a command that requires a handler to a Concur monad
-- so that the do notation can be used to compose the handler for that command.
-- The Concur monad allows scheduling the command in concurrently with other commands.
instance AsConcur cmd => MonadDelegate () (Concur cmd) where
    delegate f = Concur $ do
        v <- lift $ NewEmptyMVar newEmptyMVar
        b <- runConcur $ f (\a -> Concur $ lift $ pure $ Left $ putMVar v a)
        pure $ Left (either id pure b *> takeMVar v)
