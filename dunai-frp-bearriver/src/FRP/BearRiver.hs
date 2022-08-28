{-# LANGUAGE Arrows     #-}
{-# LANGUAGE CPP        #-}
{-# LANGUAGE RankNTypes #-}
-- The following warning is disabled so that we do not see warnings due to
-- using ListT on an MSF to implement parallelism with broadcasting.
#if __GLASGOW_HASKELL__ < 800
{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}
#else
{-# OPTIONS_GHC -Wno-deprecations #-}
#endif
-- Copyright  : (c) Ivan Perez and Manuel Baerenz, 2016
-- License    : BSD3
-- Maintainer : ivan.perez@keera.co.uk
module FRP.BearRiver
  (module FRP.BearRiver, module X)
 where
-- This is an implementation of Yampa using our Monadic Stream Processing
-- library. We focus only on core Yampa. We will use this module later to
-- reimplement an example of a Yampa system.
--
-- While we may not introduce all the complexity of Yampa today (all kinds of
-- switches, etc.) our goal is to show that the approach is promising and that
-- there do not seem to exist any obvious limitations.

-- External imports
import           Control.Applicative
import           Control.Arrow             as X
import qualified Control.Category          as Category
import           Control.Monad             (mapM)
import           Control.Monad.Random
import           Control.Monad.Trans.Maybe
import           Data.Functor.Identity
import           Data.Maybe
import           Data.Traversable          as T
import           Data.VectorSpace          as X

-- Internal imports
import           Control.Monad.Trans.MSF                 hiding (dSwitch,
                                                          switch)
import qualified Control.Monad.Trans.MSF                 as MSF
import           Control.Monad.Trans.MSF.Except          as MSF hiding (dSwitch,
                                                                 switch)
import           Control.Monad.Trans.MSF.List            (sequenceS, widthFirst)
import           Control.Monad.Trans.MSF.Random
import           Data.MonadicStreamFunction              as X hiding (dSwitch,
                                                               reactimate,
                                                               repeatedly, sum,
                                                               switch, trace)
import qualified Data.MonadicStreamFunction              as MSF
import           Data.MonadicStreamFunction.InternalCore

-- Internal imports (instances)
import Data.MonadicStreamFunction.Instances.ArrowLoop

infixr 0 -->, -:>, >--, >=-

-- * Basic definitions

-- | Absolute time.
type Time  = Double

-- | Time deltas or increments (conceptually positive).
type DTime = Double

-- | Extensible signal function (signal function with a notion of time, but
-- which can be extended with actions).
type SF m        = MSF (ClockInfo m)

-- | Information on the progress of time.
type ClockInfo m = ReaderT DTime m

-- ** Lifting
arrPrim :: Monad m => (a -> b) -> SF m a b
arrPrim = arr

arrEPrim :: Monad m => (Maybe a -> b) -> SF m (Maybe a) b
arrEPrim = arr

-- * Signal functions

-- ** Basic signal functions

identity :: Monad m => SF m a a
identity = Category.id

constant :: Monad m => b -> SF m a b
constant = arr . const

localTime :: Monad m => SF m a Time
localTime = constant 1.0 >>> integral

time :: Monad m => SF m a Time
time = localTime

-- ** Initialization

-- | Initialization operator (cf. Lustre/Lucid Synchrone).
--
-- The output at time zero is the first argument, and from
-- that point on it behaves like the signal function passed as
-- second argument.
(-->) :: Monad m => b -> SF m a b -> SF m a b
b0 --> sf = sf >>> replaceOnce b0

-- | Output pre-insert operator.
--
-- Insert a sample in the output, and from that point on, behave
-- like the given sf.
(-:>) :: Monad m => b -> SF m a b -> SF m a b
b -:> sf = iPost b sf

-- | Input initialization operator.
--
-- The input at time zero is the first argument, and from
-- that point on it behaves like the signal function passed as
-- second argument.
(>--) :: Monad m => a -> SF m a b -> SF m a b
a0 >-- sf = replaceOnce a0 >>> sf

(>=-) :: Monad m => (a -> a) -> SF m a b -> SF m a b
f >=- sf = MSF $ \a -> do
  (b, sf') <- unMSF sf (f a)
  return (b, sf')

initially :: Monad m => a -> SF m a a
initially = (--> identity)

-- * Simple, stateful signal processing
sscan :: Monad m => (b -> a -> b) -> b -> SF m a b
sscan f b_init = feedback b_init u
  where u = undefined -- (arr f >>^ dup)

sscanPrim :: Monad m => (c -> a -> Maybe (c, b)) -> c -> b -> SF m a b
sscanPrim f c_init b_init = MSF $ \a -> do
  let o = f c_init a
  case o of
    Nothing       -> return (b_init, sscanPrim f c_init b_init)
    Just (c', b') -> return (b',     sscanPrim f c' b')


-- | Event source that never occurs.
never :: Monad m => SF m a (Maybe b)
never = constant Nothing

-- | Event source with a single occurrence at time 0. The value of the event
-- is given by the function argument.
now :: Monad m => b -> SF m a (Maybe b)
now b0 = Just b0 --> never

after :: Monad m
      => Time -- ^ The time /q/ after which the event should be produced
      -> b    -- ^ Value to produce at that time
      -> SF m a (Maybe b)
after q x = feedback q go
 where go = MSF $ \(_, t) -> do
              dt <- ask
              let t' = t - dt
                  e  = if t > 0 && t' < 0 then Just x else Nothing
                  ct = if t' < 0 then constant (Nothing, t') else go
              return ((e, t'), ct)

repeatedly :: Monad m => Time -> b -> SF m a (Maybe b)
repeatedly q x
    | q > 0     = afterEach qxs
    | otherwise = error "bearriver: repeatedly: Non-positive period."
  where
    qxs = (q,x):qxs

-- | Event source with consecutive occurrences at the given intervals.
-- Should more than one event be scheduled to occur in any sampling interval,
-- only the first will in fact occur to avoid an event backlog.

-- After all, after, repeatedly etc. are defined in terms of afterEach.
afterEach :: Monad m => [(Time,b)] -> SF m a (Maybe b)
afterEach qxs = afterEachCat qxs >>> arr (fmap head)

-- | Event source with consecutive occurrences at the given intervals.
-- Should more than one event be scheduled to occur in any sampling interval,
-- the output list will contain all events produced during that interval.
afterEachCat :: Monad m => [(Time,b)] -> SF m a (Maybe [b])
afterEachCat = afterEachCat' 0
  where
    afterEachCat' :: Monad m => Time -> [(Time,b)] -> SF m a (Maybe [b])
    afterEachCat' _ [] = never
    afterEachCat' t qxs = MSF $ \_ -> do
      dt <- ask
      let (ev, t', qxs') = fireEvents [] (t + dt) qxs
          ev' = if null ev
                  then Nothing
                  else Just (reverse ev)

      return (ev', afterEachCat' t' qxs')

    fireEvents :: [b] -> Time -> [(Time,b)] -> ([b], Time, [(Time,b)])
    fireEvents ev t [] = (ev, t, [])
    fireEvents ev t (qx:qxs)
      | fst qx < 0 = error "bearriver: afterEachCat: Non-positive period."
      | otherwise =
          let overdue = t - fst qx in
          if overdue >= 0
            then fireEvents (snd qx:ev) overdue qxs
            else (ev, t, qx:qxs)

-- * Events

-- | Apply an 'MSF' to every input. Freezes temporarily if the input is
-- 'NoEvent', and continues as soon as an 'Event' is received.
mapEventS :: Monad m => MSF m a b -> MSF m (Maybe a) (Maybe b)
mapEventS msf = proc eventA -> case eventA of
  Just a -> arr Just <<< msf -< a
  Nothing -> returnA           -< Nothing

-- ** Relation to other types

eventToMaybe = event Nothing Just

boolToEvent :: Bool -> Maybe ()
boolToEvent True  = Just ()
boolToEvent False = Nothing

-- * Hybrid SF m combinators

edge :: Monad m => SF m Bool (Maybe ())
edge = edgeFrom True

iEdge :: Monad m => Bool -> SF m Bool (Maybe ())
iEdge = edgeFrom

-- | Like 'edge', but parameterized on the tag value.
--
-- From Yampa
edgeTag :: Monad m => a -> SF m Bool (Maybe a)
edgeTag a = edge >>> arr (`tag` a)

-- | Edge detector particularized for detecting transtitions
--   on a 'Maybe' signal from 'Nothing' to 'Just'.
--
-- From Yampa

-- !!! 2005-07-09: To be done or eliminated
-- !!! Maybe could be kept as is, but could be easy to implement directly
-- !!! in terms of sscan?
edgeJust :: Monad m => SF m (Maybe a) (Maybe a)
edgeJust = edgeBy isJustEdge (Just undefined)
    where
        isJustEdge Nothing  Nothing     = Nothing
        isJustEdge Nothing  ma@(Just _) = ma
        isJustEdge (Just _) (Just _)    = Nothing
        isJustEdge (Just _) Nothing     = Nothing

edgeBy :: Monad m => (a -> a -> Maybe b) -> a -> SF m a (Maybe b)
edgeBy isEdge a_prev = MSF $ \a ->
  return (maybeToEvent (isEdge a_prev a), edgeBy isEdge a)

maybeToEvent :: Maybe a -> Maybe a
maybeToEvent = maybe Nothing Just

edgeFrom :: Monad m => Bool -> SF m Bool (Maybe())
edgeFrom prev = MSF $ \a -> do
  let res | prev      = Nothing
          | a         = Just ()
          | otherwise = Nothing
      ct  = edgeFrom a
  return (res, ct)

-- * Stateful event suppression

-- | Suppression of initial (at local time 0) event.
notYet :: Monad m => SF m (Maybe a) (Maybe a)
notYet = feedback False $ arr (\(e,c) ->
  if c then (e, True) else (Nothing, True))

-- | Suppress all but the first event.
once :: Monad m => SF m (Maybe a) (Maybe a)
once = takeEvents 1

-- | Suppress all but the first n events.
takeEvents :: Monad m => Int -> SF m (Maybe a) (Maybe a)
takeEvents n | n <= 0 = never
takeEvents n = dSwitch (arr dup) (const (Nothing >-- takeEvents (n - 1)))

-- | Suppress first n events.

-- Here dSwitch or switch does not really matter.
dropEvents :: Monad m => Int -> SF m (Maybe a) (Maybe a)
dropEvents n | n <= 0  = identity
dropEvents n = dSwitch (never &&& identity)
                             (const (Nothing >-- dropEvents (n - 1)))

-- * Pointwise functions on events

noEvent :: Maybe a
noEvent = Nothing

-- | Suppress any event in the first component of a pair.
noEventFst :: (Maybe a, b) -> (Maybe c, b)
noEventFst (_, b) = (Nothing, b)


-- | Suppress any event in the second component of a pair.
noEventSnd :: (a, Maybe b) -> (a, Maybe c)
noEventSnd (a, _) = (a, Nothing)

event :: a -> (b -> a) -> Maybe b -> a
event _ f (Just x) = f x
event x _ Nothing   = x

fromEvent (Just x) = x
fromEvent _         = error "fromEvent NoEvent"

isEvent (Just _) = True
isEvent _         = False

isNoEvent (Just _) = False
isNoEvent _         = True

tag :: Maybe a -> b -> Maybe b
tag Nothing   _ = Nothing
tag (Just _) b = Just b

-- | Tags an (occurring) event with a value ("replacing" the old value). Same
-- as 'tag' with the arguments swapped.
--
-- Applicative-based definition:
-- tagWith = (<$)
tagWith :: b -> Maybe a -> Maybe b
tagWith = flip tag

-- | Attaches an extra value to the value of an occurring event.
attach :: Maybe a -> b -> Maybe (a, b)
e `attach` b = fmap (\a -> (a, b)) e

-- | Left-biased event merge (always prefer left event, if present).
lMerge :: Maybe a -> Maybe a -> Maybe a
lMerge = mergeBy (\e1 _ -> e1)

-- | Right-biased event merge (always prefer right event, if present).
rMerge :: Maybe a -> Maybe a -> Maybe a
rMerge = flip lMerge

merge :: Maybe a -> Maybe a -> Maybe a
merge = mergeBy $ error "Bearriver: merge: Simultaneous event occurrence."

mergeBy :: (a -> a -> a) -> Maybe a -> Maybe a -> Maybe a
mergeBy _       Nothing      Nothing      = Nothing
mergeBy _       le@(Just _) Nothing      = le
mergeBy _       Nothing      re@(Just _) = re
mergeBy resolve (Just l)    (Just r)    = Just (resolve l r)

-- | A generic event merge-map utility that maps event occurrences,
-- merging the results. The first three arguments are mapping functions,
-- the third of which will only be used when both events are present.
-- Therefore, 'mergeBy' = 'mapMerge' 'id' 'id'
--
-- Applicative-based definition:
-- mapMerge lf rf lrf le re = (f <$> le <*> re) <|> (lf <$> le) <|> (rf <$> re)
mapMerge :: (a -> c) -> (b -> c) -> (a -> b -> c)
            -> Maybe a -> Maybe b -> Maybe c
mapMerge _  _  _   Nothing   Nothing   = Nothing
mapMerge lf _  _   (Just l) Nothing   = Just (lf l)
mapMerge _  rf _   Nothing   (Just r) = Just (rf r)
mapMerge _  _  lrf (Just l) (Just r) = Just (lrf l r)

-- | Merge a list of events; foremost event has priority.
--
-- Foldable-based definition:
-- mergeEvents :: Foldable t => t (Event a) -> Event a
-- mergeEvents =  asum
mergeEvents :: [Maybe a] -> Maybe a
mergeEvents = foldr lMerge Nothing

-- | Collect simultaneous event occurrences; no event if none.
--
-- Traverable-based definition:
-- catEvents :: Foldable t => t (Event a) -> Event (t a)
-- carEvents e  = if (null e) then NoEvent else (sequenceA e)
catEvents :: [Maybe a] -> Maybe [a]
catEvents eas = case [ a | Just a <- eas ] of
                    [] -> Nothing
                    as -> Just as

-- | Join (conjunction) of two events. Only produces an event
-- if both events exist.
--
-- Applicative-based definition:
-- joinE = liftA2 (,)
joinE :: Maybe a -> Maybe b -> Maybe (a,b)
joinE Nothing   _         = Nothing
joinE _         Nothing   = Nothing
joinE (Just l) (Just r) = Just (l,r)

-- | Split event carrying pairs into two events.
splitE :: Maybe (a,b) -> (Maybe a, Maybe b)
splitE Nothing       = (Nothing, Nothing)
splitE (Just (a,b)) = (Just a, Just b)

------------------------------------------------------------------------------
-- Event filtering
------------------------------------------------------------------------------

-- | Filter out events that don't satisfy some predicate.
filterE :: (a -> Bool) -> Maybe a -> Maybe a
filterE p e@(Just a) = if p a then e else Nothing
filterE _ Nothing     = Nothing


-- | Combined event mapping and filtering. Note: since 'Event' is a 'Functor',
-- see 'fmap' for a simpler version of this function with no filtering.
mapFilterE :: (a -> Maybe b) -> Maybe a -> Maybe b
mapFilterE _ Nothing   = Nothing
mapFilterE f (Just a) = case f a of
                            Nothing -> Nothing
                            Just b  -> Just b


-- | Enable/disable event occurences based on an external condition.
gate :: Maybe a -> Bool -> Maybe a
_ `gate` False = Nothing
e `gate` True  = e

-- * Switching

-- ** Basic switchers

switch :: Monad m => SF m a (b, Maybe c) -> (c -> SF m a b) -> SF m a b
switch sf sfC = MSF $ \a -> do
  (o, ct) <- unMSF sf a
  case o of
    (_, Just c) -> local (const 0) (unMSF (sfC c) a)
    (b, Nothing) -> return (b, switch ct sfC)

dSwitch ::  Monad m => SF m a (b, Maybe c) -> (c -> SF m a b) -> SF m a b
dSwitch sf sfC = MSF $ \a -> do
  (o, ct) <- unMSF sf a
  case o of
    (b, Just c) -> do (_,ct') <- local (const 0) (unMSF (sfC c) a)
                      return (b, ct')
    (b, Nothing) -> return (b, dSwitch ct sfC)


-- * Parallel composition and switching

-- ** Parallel composition and switching over collections with broadcasting

#if MIN_VERSION_base(4,8,0)
parB :: (Monad m) => [SF m a b] -> SF m a [b]
#else
parB :: (Functor m, Monad m) => [SF m a b] -> SF m a [b]
#endif
parB = widthFirst . sequenceS

dpSwitchB :: (Functor m, Monad m , Traversable col)
          => col (SF m a b) -> SF m (a, col b) (Maybe c) -> (col (SF m a b) -> c -> SF m a (col b))
          -> SF m a (col b)
dpSwitchB sfs sfF sfCs = MSF $ \a -> do
  res <- T.mapM (`unMSF` a) sfs
  let bs   = fmap fst res
      sfs' = fmap snd res
  (e,sfF') <- unMSF sfF (a, bs)
  ct <- case e of
          Just c -> snd <$> unMSF (sfCs sfs c) a
          Nothing -> return (dpSwitchB sfs' sfF' sfCs)
  return (bs, ct)

-- ** Parallel composition over collections

parC :: Monad m => SF m a b -> SF m [a] [b]
parC sf = parC0 sf
  where
    parC0 :: Monad m => SF m a b -> SF m [a] [b]
    parC0 sf0 = MSF $ \as -> do
      os <- T.mapM (\(a,sf) -> unMSF sf a) $ zip as (replicate (length as) sf0)
      let bs  = fmap fst os
          cts = fmap snd os
      return (bs, parC' cts)

    parC' :: Monad m => [SF m a b] -> SF m [a] [b]
    parC' sfs = MSF $ \as -> do
      os <- T.mapM (\(a,sf) -> unMSF sf a) $ zip as sfs
      let bs  = fmap fst os
          cts = fmap snd os
      return (bs, parC' cts)

-- * Discrete to continuous-time signal functions

-- ** Wave-form generation

hold :: Monad m => a -> SF m (Maybe a) a
hold a = feedback a $ arr $ \(e,a') ->
    dup (event a' id e)
  where
    dup x = (x,x)

-- ** Accumulators

-- | Accumulator parameterized by the accumulation function.
accumBy :: Monad m => (b -> a -> b) -> b -> SF m (Maybe a) (Maybe b)
accumBy f b = mapEventS $ accumulateWith (flip f) b

accumHoldBy :: Monad m => (b -> a -> b) -> b -> SF m (Maybe a) b
accumHoldBy f b = feedback b $ arr $ \(a, b') ->
  let b'' = event b' (f b') a
  in (b'', b'')

-- * State keeping combinators

-- ** Loops with guaranteed well-defined feedback
loopPre :: Monad m => c -> SF m (a, c) (b, c) -> SF m a b
loopPre = feedback

-- * Integration and differentiation

integral :: (Monad m, VectorSpace a s) => SF m a a
integral = integralFrom zeroVector

integralFrom :: (Monad m, VectorSpace a s) => a -> SF m a a
integralFrom a0 = proc a -> do
  dt <- constM ask         -< ()
  accumulateWith (^+^) a0 -< realToFrac dt *^ a

derivative :: (Monad m, VectorSpace a s) => SF m a a
derivative = derivativeFrom zeroVector

derivativeFrom :: (Monad m, VectorSpace a s) => a -> SF m a a
derivativeFrom a0 = proc a -> do
  dt   <- constM ask   -< ()
  aOld <- MSF.iPre a0 -< a
  returnA             -< (a ^-^ aOld) ^/ realToFrac dt

-- NOTE: BUG in this function, it needs two a's but we
-- can only provide one
iterFrom :: Monad m => (a -> a -> DTime -> b -> b) -> b -> SF m a b
iterFrom f b = MSF $ \a -> do
  dt <- ask
  let b' = f a a dt b
  return (b, iterFrom f b')

-- * Noise (random signal) sources and stochastic event sources

occasionally :: MonadRandom m
             => Time -- ^ The time /q/ after which the event should be produced on average
             -> b    -- ^ Value to produce at time of event
             -> SF m a (Maybe b)
occasionally tAvg b
  | tAvg <= 0 = error "bearriver: Non-positive average interval in occasionally."
  | otherwise = proc _ -> do
      r   <- getRandomRS (0, 1) -< ()
      dt  <- timeDelta          -< ()
      let p = 1 - exp (-(dt / tAvg))
      returnA -< if r < p then Just b else Nothing
 where
  timeDelta :: Monad m => SF m a DTime
  timeDelta = constM ask

-- * Execution/simulation

-- ** Reactimation

reactimate :: Monad m => m a -> (Bool -> m (DTime, Maybe a)) -> (Bool -> b -> m Bool) -> SF Identity a b -> m ()
reactimate senseI sense actuate sf = do
  -- runMaybeT $ MSF.reactimate $ liftMSFTrans (senseSF >>> sfIO) >>> actuateSF
  MSF.reactimateB $ senseSF >>> sfIO >>> actuateSF
  return ()
 where sfIO        = morphS (return.runIdentity) (runReaderS sf)

       -- Sense
       senseSF     = MSF.dSwitch senseFirst senseRest

       -- Sense: First sample
       senseFirst = constM senseI >>> arr (\x -> ((0, x), Just x))

       -- Sense: Remaining samples
       senseRest a = constM (sense True) >>> (arr id *** keepLast a)

       keepLast :: Monad m => a -> MSF m (Maybe a) a
       keepLast a = MSF $ \ma -> let a' = fromMaybe a ma in a' `seq` return (a', keepLast a')

       -- Consume/render
       -- actuateSF :: MSF IO b ()
       -- actuateSF    = arr (\x -> (True, x)) >>> liftMSF (lift . uncurry actuate) >>> exitIf
       actuateSF    = arr (\x -> (True, x)) >>> arrM (uncurry actuate)

-- * Debugging / Step by step simulation

-- | Evaluate an SF, and return an output and an initialized SF.
--
--   /WARN/: Do not use this function for standard simulation. This function is
--   intended only for debugging/testing. Apart from being potentially slower
--   and consuming more memory, it also breaks the FRP abstraction by making
--   samples discrete and step based.
evalAtZero :: SF Identity a b -> a -> (b, SF Identity a b)
evalAtZero sf a = runIdentity $ runReaderT (unMSF sf a) 0

-- | Evaluate an initialized SF, and return an output and a continuation.
--
--   /WARN/: Do not use this function for standard simulation. This function is
--   intended only for debugging/testing. Apart from being potentially slower
--   and consuming more memory, it also breaks the FRP abstraction by making
--   samples discrete and step based.
evalAt :: SF Identity a b -> DTime -> a -> (b, SF Identity a b)
evalAt sf dt a = runIdentity $ runReaderT (unMSF sf a) dt

-- | Given a signal function and time delta, it moves the signal function into
--   the future, returning a new uninitialized SF and the initial output.
--
--   While the input sample refers to the present, the time delta refers to the
--   future (or to the time between the current sample and the next sample).
--
--   /WARN/: Do not use this function for standard simulation. This function is
--   intended only for debugging/testing. Apart from being potentially slower
--   and consuming more memory, it also breaks the FRP abstraction by making
--   samples discrete and step based.
--
evalFuture :: SF Identity a b -> a -> DTime -> (b, SF Identity a b)
evalFuture sf = flip (evalAt sf)

-- * Auxiliary functions

-- ** Event handling
replaceOnce :: Monad m => a -> SF m a a
replaceOnce a = dSwitch (arr $ const (a, Just ())) (const $ arr id)

-- ** Tuples
dup  x     = (x,x)
