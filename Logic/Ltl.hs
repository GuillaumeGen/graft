{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | A re-implementation of the "LTL" module from cooked-validators using
-- "Fipxoint.Api".
--
-- This is the version this is based upon:
-- https://github.com/tweag/cooked-validators/blob/a460c1718d8d21bada510d83b705b24b0f8d36e0/src/Cooked/Ltl.hs
module Logic.Ltl
  ( Ltl (..),
    somewhere,
    everywhere,
    modifyLtl,
    InterpretLtl (..),
    Functor2 (..),
    LtlInterp (..),
    InterpretLtlHigherOrder (..),
    LtlAST,
    interpretLtlAST,
    interpretLtlASTWithInitialFormulas,
    InterpretEffectsLtl,
    nowLaterList,
  )
where

import Control.Arrow
import Control.Monad
import Control.Monad.Writer
import Data.Functor.Const
import Data.Kind
import Effect

-- * LTL formulas and operations on them

-- | Type of LTL formulas with atomic formulas of type @a@. Think of @a@ as a
-- type of "modifications", then a value of type @Ltl a@ describes where to
-- apply modifications. Since it does not make (obvious) sense to talk of a
-- negated modification or of one modification (possibly in the future) to
-- imply another modification, implication and negation are absent.
data Ltl a
  = -- | The "do nothing" modification that never fails
    LtlTruth
  | -- | The modification that never applies (i.e. always fails)
    LtlFalsity
  | -- | The modification that applies a given atomic modification at the current time step
    LtlAtom a
  | -- | Disjunction will be interpreted in an "intuitionistic" way, i.e. as
    -- branching into the "timeline" where the left disjunct holds and the one
    -- where the right disjunct holds. In that sense, it is an exclusive or,
    -- as it does not introduce the branch where both disjuncts hold.
    LtlOr (Ltl a) (Ltl a)
  | -- | Conjunction will be interpreted as "apply both
    -- modifications". Attention: The "apply both" operation will be
    -- user-defined for atomic modifications, so that conjunction may for
    -- example fail to be commutative if the operation on atomic modification is
    -- not commutative.
    LtlAnd (Ltl a) (Ltl a)
  | -- | Assert that the given formula holds at the next time step.
    LtlNext (Ltl a)
  | -- | Assert that the first formula holds at least until the second one begins
    -- to hold, which must happen eventually. The formulas
    -- > a `LtlUntil` b
    -- and
    -- > b `LtlOr` (a `LtlAnd` LtlNext (a `LtlUntil` b))
    -- are equivalent.
    LtlUntil (Ltl a) (Ltl a)
  | -- | Assert that the second formula has to be true up to and including the
    -- point when the first one becomes true; if that never happens, the second
    -- formula has to remain true forever. View this as dual to 'LtlUntil'. The
    -- formulas
    -- > a `LtlRelease` b
    -- and
    -- > b `LtlAnd` (a `LtlOr` LtlNext (a `LtlRelease` b))
    -- are equivalent.
    LtlRelease (Ltl a) (Ltl a)
  deriving (Show)

somewhere :: a -> Ltl a
somewhere a = LtlTruth `LtlUntil` LtlAtom a

everywhere :: a -> Ltl a
everywhere a = LtlFalsity `LtlRelease` LtlAtom a

-- | Split an LTL formula that describes a modification of a computation into a
-- list of @(doNow, doLater)@ pairs, where
--
-- * @doNow@ is @Just@ the modification to be applied to the current time step,
--   or @Nothing@, if no modification needs to be applied,
--
-- * @doLater@ is an LTL formula describing the composite modification that
--   should be applied from the next time step onwards, and
--
-- The return value is a list because a formula might be satisfied in different
-- ways. For example, the modification described by @a `LtlUntil` b@ might be
-- accomplished by applying the modification @b@ right now, or by applying @a@
-- right now and @a `LtlUntil` b@ from the next step onwards; the returned list
-- will contain these two options.
--
-- Modifications should form a 'Semigroup', where '<>' is the composition of
-- modifications. We interpret @a <> b@ as the modification that first applies
-- @b@ and then @a@. Attention: Since we use '<>' to define conjunction, if '<>'
-- is not commutative, conjunction will also fail to be commutative!
nowLater :: (Semigroup a) => Ltl a -> [(Maybe a, Ltl a)]
nowLater LtlTruth = [(Nothing, LtlTruth)]
nowLater LtlFalsity = []
nowLater (LtlAtom g) = [(Just g, LtlTruth)]
nowLater (a `LtlOr` b) = nowLater a ++ nowLater b
nowLater (a `LtlAnd` b) =
  [ ( f <> g,
      ltlSimpl $ c `LtlAnd` d
    )
    | (f, c) <- nowLater a,
      (g, d) <- nowLater b
  ]
nowLater (LtlNext a) = [(Nothing, a)]
nowLater (a `LtlUntil` b) =
  nowLater $ b `LtlOr` (a `LtlAnd` LtlNext (a `LtlUntil` b))
nowLater (a `LtlRelease` b) =
  nowLater $ b `LtlAnd` (a `LtlOr` LtlNext (a `LtlRelease` b))

-- | If there are no more steps and the next step should satisfy the given
-- formula: Are we finished, i.e. was the initial formula satisfied by now?
finished :: Ltl a -> Bool
finished LtlTruth = True
finished LtlFalsity = False
finished (LtlAtom _) = False
finished (a `LtlAnd` b) = finished a && finished b
finished (a `LtlOr` b) = finished a || finished b
finished (LtlNext _) = False
finished (LtlUntil _ _) = False
finished (LtlRelease _ _) = True

-- | Say we're passing around more than one formula from each time step to the
-- next, where the intended meaning of a list of formulas is the modification
-- that applies the first formula in the list first, then the second formula,
-- then the third and so on. We'd still like to compute a list of @(doNow,
-- doLater)@ pairs as in 'nowLater', only that the @doLater@ should again be a
-- list of formulas.
nowLaterList :: (Semigroup a) => [Ltl a] -> [(Maybe a, [Ltl a])]
nowLaterList = joinNowLaters . map nowLater
  where
    joinNowLaters [] = [(mempty, [])]
    joinNowLaters (l : ls) =
      [ (g <> f, c : cs)
        | (f, c) <- l,
          (g, cs) <- joinNowLaters ls
      ]

-- | Straightforward simplification procedure for LTL formulas. This function
-- knows how 'LtlTruth' and 'LtlFalsity' play with conjunction and disjunction
-- and recursively applies this knowledge; it does not do anything "fancy" like
-- computing a normal form and is only used to keep the formulas 'nowLater'
-- generates from growing too wildly.
ltlSimpl :: Ltl a -> Ltl a
ltlSimpl expr =
  let (expr', progress) = simpl expr
   in if progress then expr' else expr
  where
    simpl :: Ltl a -> (Ltl a, Bool)
    simpl (LtlAnd a b) = simplAnd a b
    simpl (LtlOr a b) = simplOr a b
    simpl (LtlNext a) =
      let (a', pa) = simpl a
       in if pa
            then (LtlNext a', True)
            else (LtlNext a, False)
    simpl (LtlUntil a b) = recurse2 LtlUntil a b
    simpl (LtlRelease a b) = recurse2 LtlRelease a b
    simpl x = (x, False)

    simplAnd :: Ltl a -> Ltl a -> (Ltl a, Bool)
    simplAnd a b =
      let (a', pa) = simpl a
          (b', pb) = simpl b
       in case (a', b') of
            (LtlTruth, _) -> (b', True)
            (_, LtlTruth) -> (a', True)
            (LtlFalsity, _) -> (LtlFalsity, True)
            (_, LtlFalsity) -> (LtlFalsity, True)
            _ -> if pa || pb then (LtlAnd a' b', True) else (LtlAnd a b, False)

    simplOr :: Ltl a -> Ltl a -> (Ltl a, Bool)
    simplOr a b =
      let (a', pa) = simpl a
          (b', pb) = simpl b
       in case (a', b') of
            (LtlTruth, _) -> (LtlTruth, True)
            (_, LtlTruth) -> (LtlTruth, True)
            (LtlFalsity, _) -> (b', True)
            (_, LtlFalsity) -> (a', True)
            _ -> if pa || pb then (LtlOr a' b', True) else (LtlOr a b, False)

    recurse2 ::
      (Ltl a -> Ltl a -> Ltl a) ->
      Ltl a ->
      Ltl a ->
      (Ltl a, Bool)
    recurse2 f a b =
      let (a', pa) = simpl a
          (b', pb) = simpl b
       in if pa || pb
            then (f a' b', True)
            else (f a b, False)

-- * 'AST's with 'Ltl' formulas.

-- ** The 'MonadLtl' class

data LtlOperation mod (m :: Type -> Type) a where
  ModifyLtl :: Ltl mod -> m a -> LtlOperation mod m a

instance
  {-# OVERLAPPING #-}
  (MonadPlus m) =>
  InterpretEffectStateful (Const [Ltl mod]) m (LtlOperation mod)
  where
  interpretEffectStateful evalActs ltls (ModifyLtl ltl acts) = do
    (a, Const ltls') <- evalActs (Const $ ltl : getConst ltls) acts
    if finished . head $ ltls'
      then return (a, Const ltls')
      else mzero

type LtlAST mod ops = AST (LtlOperation mod ': ops)

modifyLtl :: Ltl mod -> LtlAST mod ops -> LtlAST mod ops
modifyLtl = astInject . ModifyLtl

-- ** Obtaining instances of 'MonadLtl'

class Functor2 t where
  fmap2 :: (forall a. f a -> g a) -> t f -> t g

data LtlInterp (mod :: Type) (m :: Type -> Type) (ops :: [(Type -> Type) -> Type -> Type]) (a :: Type) where
  Direct :: (mod -> m (Maybe a)) -> LtlInterp mod m ops a
  Nested ::
    (Functor2 nestty) =>
    ([Ltl mod] -> nestty (AST ops)) ->
    (nestty (WriterT [Ltl mod] m) -> m (a, [Ltl mod])) ->
    LtlInterp mod m ops a

class InterpretLtlHigherOrder mod m op where
  interpretLtlHigherOrder :: op (AST ops) a -> LtlInterp mod m ops a

class InterpretLtl mod m op where
  interpretLtl :: op dummy a -> mod -> m (Maybe a)

instance (InterpretLtl mod m op) => InterpretLtlHigherOrder mod m op where
  interpretLtlHigherOrder = Direct . interpretLtl

instance
  ( Semigroup mod,
    MonadPlus m,
    InterpretEffect m op,
    InterpretLtlHigherOrder mod m op
  ) =>
  InterpretEffectStateful (Const [Ltl mod]) m op
  where
  interpretEffectStateful evalActs (Const ltls) op =
    case interpretLtlHigherOrder op of
      Nested subASTs unnest ->
        fmap (second Const)
          . unnest
          . fmap2 (WriterT . fmap (second getConst) . evalActs (Const ltls))
          $ subASTs ltls
      Direct direct ->
        msum $
          map
            ( \(now, later) ->
                case now of
                  Nothing ->
                    (,Const later)
                      <$> interpretEffect
                        (fmap fst . evalActs (Const []))
                        op
                  Just x -> do
                    mA <- direct x
                    case mA of
                      Nothing -> mzero
                      Just a -> return (a, Const later)
            )
            (nowLaterList ltls)

-- ** Interpreting 'AST's with 'Ltl' formulas

type InterpretEffectsLtl mod m ops = InterpretEffectsStateful (Const [Ltl mod]) m ops

-- | interpret a list of 'Ltl' formulas and an 'AST' into a 'MonadPlus' domain,
-- and prune all branches where the formulas are not all 'finished' after the
-- complete evaluation of the 'AST'.
interpretLtlASTWithInitialFormulas :: (Semigroup mod, MonadPlus m, InterpretEffectsLtl mod m ops) => [Ltl mod] -> LtlAST mod ops a -> m a
interpretLtlASTWithInitialFormulas ltls acts = do
  (a, finals) <- interpretASTStateful (Const ltls) acts
  if all finished finals
    then return a
    else mzero

-- | This is 'interpretASTLtlWithInitialFormulas', with an empty initial
-- composite modification. This function has an ambiguous type, and you'll have
-- to type-apply it to tye type of the atomic modifications to avoid
-- "Overlapping instances" errors.
interpretLtlAST :: forall mod m ops a. (Semigroup mod, MonadPlus m, InterpretEffectsLtl mod m ops) => LtlAST mod ops a -> m a
interpretLtlAST = interpretLtlASTWithInitialFormulas ([] @(Ltl mod))
