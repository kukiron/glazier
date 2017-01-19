{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Glazier.Strict where
    -- ( Gadget(..)
    -- , Widget(..)
    -- , HasWindow(..)
    -- , HasGadget(..)
    -- , statically
    -- , dynamically
    -- ) where

import Control.Arrow
import Control.Applicative
import Control.Lens
import Control.Monad.Reader
import Control.Monad.RWS.CPS hiding ((<>))
import Control.Monad.Trans.RWS.CPS.Internal (RWST(..))
import Control.Monad.Trans.RWS.CPS.Lens ()
import Data.Functor.Apply
import Data.Maybe
import Data.Semigroup
import Glazier
import qualified Control.Monad.Fail as Fail
import Control.Monad.Morph
import qualified Control.Category as C
import Control.Monad.Fix (MonadFix)
import Data.Profunctor

-- | The Elm update function is @a -> s -> (s, c)@
-- This is isomorphic to @ReaderT a (State s) c@
-- ie, given an action "a", and a current state "s", return the new state "s"
-- and any commands "c" that need to be interpreted externally (eg. download file).
-- This is named Gadget instead of Update to avoid confusion with update from Data.Map
-- This is also further enhanced with monadic and Writer effect, so we can just use RWST to avoid
-- writing new code.
newtype Gadget w s m a c = Gadget
    { runGadget :: RWST a w s m c
    } deriving ( MonadState s
               , MonadWriter w
               , MonadReader a
               , Monad
               , Applicative
               , Functor
               , Fail.MonadFail
               , Alternative
               , MonadPlus
               , MonadFix
               , MonadIO
               )

makeWrapped ''Gadget

liftGadget :: (MonadTrans t, Monad m) => Gadget w s m a c -> Gadget w s (t m) a c
liftGadget (Gadget (RWST f)) = Gadget $ RWST $ \a s w -> lift (f a s w)

hoistGadget :: (Monad m) => (forall x. m x -> n x) -> Gadget w s m a c -> Gadget w s n a c
hoistGadget f (Gadget m) = Gadget $ hoist f m

underGadget :: (Functor m', Monoid w, Monoid w') => ((a -> s -> m (c, s, w)) -> (a' -> s' -> m' (c', s', w'))) -> Gadget w s m a c -> Gadget w' s' m' a' c'
underGadget f (Gadget (RWST m)) = Gadget $ rwsT $ f (\a s -> m a s mempty)

instance (Monad m, Semigroup c) => Semigroup (Gadget w s m a c) where
    (Gadget f) <> (Gadget g) = Gadget $ (<>) <$> f <*> g

instance (Monad m, Monoid c) => Monoid (Gadget w s m a c) where
    mempty = Gadget $ pure mempty
    (Gadget f) `mappend` (Gadget g) = Gadget $ mappend <$> f <*> g

-- FIXME: Move to a new package
instance MFunctor (RWST r w s) where
    hoist nat (RWST m) = RWST (\r s w -> nat (m r s w))

instance Monad m => Profunctor (Gadget w s m) where
    dimap f g (Gadget (RWST m)) = Gadget $ RWST $ \a s w ->
        (\(c, s', w') -> (g c, s', w')) <$> m (f a) s w

instance Monad m => Strong (Gadget w s m) where
    first' (Gadget (RWST bc)) = Gadget $ RWST $ \(b, d) s w ->
        (\(c, s', w') -> ((c, d), s', w')) <$> bc b s w

instance Monad m => C.Category (Gadget w s m) where
    id = Gadget $ RWST $ \a s w -> pure (a, s, w)
    Gadget (RWST bc) . Gadget (RWST ab) = Gadget $ RWST $ \a s w -> do
        (b, s', w') <- ab a s w
        bc b s' w'

instance Monad m => Arrow (Gadget w s m) where
    arr f = dimap f id C.id
    first = first'

instance Monad m => Choice (Gadget w s m) where
    left' (Gadget (RWST bc)) = Gadget $ RWST $ \db s w -> case db of
        Left b -> do
            (c, s', w') <- bc b s w
            pure (Left c, s', w')
        Right d -> pure (Right d, s, w)

instance Monad m => ArrowChoice (Gadget w s m) where
    left = left'

instance Monad m => ArrowApply (Gadget w s m) where
    app = Gadget $ RWST $ \(Gadget (RWST bc), b) s w -> bc b s w

instance MonadPlus m => ArrowZero (Gadget w s m) where
    zeroArrow = Gadget mzero

instance MonadPlus m => ArrowPlus (Gadget w s m) where
    Gadget a <+> Gadget b = Gadget (a `mplus` b)

-- | zoom can be used to modify the state inside an Gadget
type instance Zoomed (Gadget w s m a) = Zoomed (RWST a w s m)
instance Monad m => Zoom (Gadget w s m a) (Gadget w t m a) s t where
  zoom l = Gadget . zoom l . runGadget
  {-# INLINE zoom #-}

-- | magnify can be used to modify the action inside an Gadget
type instance Magnified (Gadget w s m a) = Magnified (RWST a w s m)
instance Monad m => Magnify (Gadget w s m a) (Gadget w s m b) a b where
  magnify l = Gadget . magnify l . runGadget
  {-# INLINE magnify #-}

type instance Implanted (Gadget w s m a c) = Zoomed (Gadget w s m a) c
instance Monad m => Implant (Gadget w s m a c) (Gadget w t m a c) s t where
    implant = zoom

type instance Dispatched (Gadget w s m a c) = Magnified (Gadget w s m a) c
instance Monad m => Dispatch (Gadget w s m a c) (Gadget w s m b c) a b where
    dispatch = magnify

-------------------------------------------------------------------------------

-- | A widget is basically a tuple with Gadget and Window.
data Widget w s v m a c = Widget
  { widgetWindow :: Window m s v
  , widgetGadget :: Gadget w s m a c
  }

makeFields ''Widget

liftWidget :: (MonadTrans t, Monad m) => Widget w s v m a c -> Widget w s v (t m) a c
liftWidget (Widget w g) = Widget (liftWindow w) (liftGadget g)

hoistWidget :: (Monad m) => (forall x. m x -> n x) -> Widget w s v m a c -> Widget w s v n a c
hoistWidget f (Widget w g) = Widget (hoistWindow f w) (hoistGadget f g)

instance (Monad m, Semigroup c, Semigroup v) => Semigroup (Widget w s v m a c) where
    w1 <> w2 = Widget
      (widgetWindow w1 <> widgetWindow w2)
      (widgetGadget w1 <> widgetGadget w2)

instance (Monad m, Monoid c, Monoid v) => Monoid (Widget w s v m a c) where
    mempty = Widget mempty mempty
    mappend w1 w2 = Widget
        (widgetWindow w1 `mappend` widgetWindow w2)
        (widgetGadget w1 `mappend` widgetGadget w2)

-- | Widget Functor is lawful
-- 1: fmap id  =  id
-- (Widget w g) = Widget w (id <$> g) =  Widget w g
-- 2: fmap (f . g) = fmap f . fmap g
-- (Widget w gad) = Widget w ((f . g) <$> gad) = Widget w ((fmap f . fmap g) gad)
instance Functor m => Functor (Widget w s v m a) where
    fmap f (Widget w g) = Widget
        w
        (f <$> g)

-- | Widget Applicative is lawful
-- Identity: pure id <*> v = v
-- Widget mempty (pure id) <*> Widget vw vg
--     = Widget (mempty <> vw) (pure id <*> vg)
--     = Widget vw vg
-- Composition: pure (.) <*> u <*> v <*> w = u <*> (v <*> w)
-- Widget mempty (pure (.)) <*> Widget uw ug <*> Widget vw vg <*> Widget ww wg =
--     = Widget (mempty <> uw <> vw <> ww) (pure (.) <*> ug <*> vg <*> wg
--     = Widget (uw <> vw <> ww) (ug <*> (vg <*> wg))
--     = Widget (uw <> (vw <> ww)) (ug <*> (vg <*> wg))
--     = Widget uw ug <*> (Widget vw vg <*> Widget ww wg)
-- Interchange: u <*> pure y = pure ($ y) <*> u
-- Widget uw ug <*> Widget mempty (pure y)
--     = Widget (uw <> mempty) (ug <*> pure y)
--     = Widget (mempty <> uw) (pure ($ y) <*> ug)
--     = Widget mempty (pure $y) <*> Widget uw ug
instance (Semigroup v, Monad m, Monoid v) => Applicative (Widget w s v m a) where
    pure c = Widget mempty (pure c)
    (Widget w1 fg) <*> (Widget w2 g) = Widget (w1 <> w2) (fg <*> g)

instance Monad m => Profunctor (Widget w s v m) where
    dimap f g (Widget w m) = Widget w (dimap f g m)

instance Monad m => Strong (Widget w s v m) where
    first' (Widget w g) = Widget w (first' g)

instance (Monad m, Monoid v) => C.Category (Widget w s v m) where
    id = Widget mempty C.id
    Widget wbc gbc . Widget wab gab = Widget
        (wab `mappend` wbc)
        (gbc C.. gab)

-- | No monad instance for Widget is possible, however an arrow is possible.
-- The Arrow instance monoidally appends the Window, and uses the inner Gadget Arrow instance.
instance (Monad m, Monoid v) => Arrow (Widget w s v m) where
    arr f = dimap f id C.id
    first = first'

instance (Monad m) => Choice (Widget w s v m) where
    left' (Widget w bc) = Widget w (left' bc)

instance (Monad m, Monoid v) => ArrowChoice (Widget w s v m) where
    left = left'

statically :: (Monad m, Monoid c) => Window m s v -> Widget w s v m a c
statically w = Widget w mempty

dynamically :: (Monad m, Monoid v) => Gadget w s m a c -> Widget w s v m a c
dynamically = Widget mempty

type instance Dispatched (Widget w s v m a c) = Dispatched (Gadget w s m a c)
instance Monad m => Dispatch (Widget w s v m a c) (Widget w s v m b c) a b where
  dispatch p w = Widget
    (widgetWindow w)
    (dispatch p $ widgetGadget w)

type instance Implanted (Widget w s v m a c) =
     PairMaybeFunctor (Implanted (Gadget w s m a c))
       (Implanted (Window m s v))
instance Monad m => Implant (Widget w s v m a c) (Widget w t v m a c) s t where
  implant l w = Widget
    (implant (sndLensLike l) $ widgetWindow w)
    (implant (fstLensLike l) $ widgetGadget w)

-- -------------------------------------------------------------------------------

-- | This can be used to hold two LensLike functors.
-- The inner LensLike functor can be extracted from a @LensLike (PairMaybeFunctor f g) s t a b@
-- using 'fstLensLike' or 'sndLensLike'.
-- NB. The constructor must not be exported to keep 'fstLensLike' and 'sndLensLike' safe.
newtype PairMaybeFunctor f g a = PairMaybeFunctor { getPairMaybeFunctor :: (Maybe (f a), Maybe (g a)) }

instance (Functor f, Functor g) => Functor (PairMaybeFunctor f g) where
  fmap f (PairMaybeFunctor (a, b)) = PairMaybeFunctor (fmap f <$> a, fmap f <$> b)

instance (Apply f, Apply g) => Apply (PairMaybeFunctor f g) where
  (PairMaybeFunctor (a, b)) <.> (PairMaybeFunctor (c, d)) = PairMaybeFunctor (liftA2 (Data.Functor.Apply.<.>) a c, liftA2 (Data.Functor.Apply.<.>) b d)

instance (Applicative f, Applicative g) => Applicative (PairMaybeFunctor f g) where
  pure a = PairMaybeFunctor (Just $ pure a, Just $ pure a)
  (PairMaybeFunctor (a, b)) <*> (PairMaybeFunctor (c, d)) = PairMaybeFunctor (liftA2 (<*>) a c, liftA2 (<*>) b d)

instance (Contravariant f, Contravariant g) => Contravariant (PairMaybeFunctor f g) where
  contramap f (PairMaybeFunctor (a, b)) = PairMaybeFunctor (contramap f <$> a, contramap f <$> b)

fstLensLike :: LensLike (PairMaybeFunctor f g) s t a b -> LensLike f s t a b
-- fromJust is safe here as the constructor is hidden and we've definitely filled in the fst item of PairMaybeFunctor
fstLensLike l f b = fromJust . fst . getPairMaybeFunctor $ l (\a -> PairMaybeFunctor (Just $ f a, Nothing)) b

sndLensLike :: LensLike (PairMaybeFunctor f g) s t a b -> LensLike g s t a b
-- fromJust is safe here as the constructor is hidden and we've definitely filled in the snd item of PairMaybeFunctor
sndLensLike l f b = fromJust . snd . getPairMaybeFunctor $ l (\a -> PairMaybeFunctor (Nothing, Just $ f a)) b