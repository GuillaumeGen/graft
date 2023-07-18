{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}

module Examples where

import Control.Applicative
import Control.Monad
import Control.Monad.Identity
import Control.Monad.State
import Control.Monad.Writer
import Effect
import Effect.State
import Effect.Writer
import Logic.Ltl

-- * example domain

newtype DomainT s w m a = DomainT {unDomain :: (StateT s (WriterT w m)) a}

type Domain s w a = DomainT s w Identity a

runDomainT :: (Monoid w, Monad m) => s -> DomainT s w m a -> m (a, w)
runDomainT start (DomainT a) = runWriterT . flip evalStateT start $ a

instance (Functor m) => Functor (DomainT s w m) where
  fmap f (DomainT x) = DomainT . fmap f $ x

instance (Monad m, Monoid w, Applicative m) => Applicative (DomainT s w m) where
  pure = DomainT . pure
  (<*>) = ap

instance (Monoid w, Monad m) => Monad (DomainT s w m) where
  DomainT x >>= f = DomainT $ x >>= unDomain . f

instance (Monoid w, MonadPlus m) => Alternative (DomainT s w m) where
  empty = DomainT mzero
  DomainT a <|> DomainT b = DomainT $ a `mplus` b

instance (Monoid w, MonadPlus m) => MonadPlus (DomainT s w m)

instance (Monoid w, Monad m) => MonadState s (DomainT s w m) where
  get = DomainT get
  put x = DomainT $ put x

instance (Monoid w, Monad m) => MonadWriter w (DomainT s w m) where
  tell = DomainT . tell
  listen = DomainT . listen . unDomain
  pass = DomainT . pass . unDomain

-- * reifying and interpreting the operations of the example domain

type ExampleOperations s w = '[WriterOperation w, StateOperation s]

interpretAndRun ::
  (Monoid w) =>
  s ->
  AST (ExampleOperations s w) a ->
  (a, w)
interpretAndRun start = runIdentity . runDomainT start . interpretAST

-- * example modifications

-- ** LTL-style

-- | These "atomic" modifications have no intrinsic meaning. They'll be given a
-- meaning by the 'InterpretLtl' instance.
data Modification = ModA | ModB | ModAB deriving (Show)

instance Semigroup Modification where
  ModA <> ModA = ModA
  ModB <> ModB = ModB
  _ <> _ = ModAB

instance (MonadWriter String m, Show s, MonadState s m, MonadPlus m) => InterpretLtl Modification m (StateOperation s) where
  interpretLtl op mod =
    case (mod, op) of
      (ModA, Put s) -> do
        sOld <- get
        tell ("[" ++ show sOld ++ "-->" ++ show s ++ "]") -- tell the modification of the state
        put s
        return $ Just ()
      (ModB, Put _) -> return $ Just () -- don't change the state
      _ -> return Nothing

-- | TODO types like these (and their 'Functor2' instances) should be automatically defined
data Identity2 a f where
  Identity2 :: f a -> Identity2 a f

instance Functor2 (Identity2 a) where
  fmap2 f (Identity2 x) = Identity2 $ f x

instance {-# OVERLAPPING #-} (MonadWriter w m, MonadPlus m) => InterpretLtlHigherOrder Modification m (WriterOperation w) where
  interpretLtlHigherOrder (Tell _) = Direct $ const $ return Nothing
  interpretLtlHigherOrder (Listen acts) =
    Nested
      (const $ Identity2 acts)
      ( \(Identity2 (WriterT evaluatedActs)) -> do
          ((a, ltls'), w) <- listen evaluatedActs
          return ((a, w), ltls')
      )
  interpretLtlHigherOrder (Pass acts) =
    Nested
      (const $ Identity2 acts)
      ( \(Identity2 (WriterT evaluatedActs)) ->
          pass $ do
            ((a, f), ltls') <- evaluatedActs
            return ((a, ltls'), f)
      )

-- * Example traces

trace1 :: (MonadWriter String m, MonadState Integer m) => m ()
trace1 = put 1 >> get >>= tell . show >> put 2 >> get >>= tell . show

trace2 :: (MonadWriter String m, MonadState Integer m) => m ((), String)
trace2 = listen $ put 1 >> get >>= tell . show

trace3 :: (MonadWriter String m, MonadState Integer m) => m ((), String)
trace3 = put 1 >> get >>= tell . show >> listen (put 2 >> get >>= tell . show)

trace4 :: (MonadWriter String m, MonadState Integer m) => m ((), String)
trace4 = listen (put 1 >> get >>= tell . show >> put 2 >> get >>= tell . show)

interpretAndRunLtl ::
  Integer ->
  AST (LtlOperation Modification ': ExampleOperations Integer String) a ->
  [(a, String)]
interpretAndRunLtl start acts = runDomainT start $ (interpretASTLtl @Modification) acts

example1a, example1b :: [((), String)]
example1a = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModA) trace1
example1b = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModB) trace1

example2a, example3a, example4a, example2b, example3b, example4b :: [(((), String), String)]
example2a = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModA) trace2
example3a = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModA) trace3
example4a = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModA) trace4
example2b = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModB) trace2
example3b = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModB) trace3
example4b = interpretAndRunLtl (-1) $ modifyLtl (somewhere ModB) trace4
