module Stlc.Gentzen
  ( gentzendiagram
  , showProofTree
  )
where

import Stlc.Types
import Stlc.Block
import Lambda
import NamedLambda
import Data.Bifunctor
import qualified Data.Map as Map


data ProofTree a l = Inference a | Deduction a l [ProofTree a l]

instance Bifunctor ProofTree where
  bimap f _ (Inference a)      = Inference (f a)
  bimap f g (Deduction a l ps) = Deduction (f a) (g l) (map (bimap f g) ps)

proofBlock :: ProofTree String String -> Block
proofBlock (Inference x)      = textBlock x
proofBlock (Deduction x l xs) = deductionBlock (textBlock x) l (map proofBlock xs)

-- | Draws a complete derivation tree
showProofTree :: ProofTree String String -> String
showProofTree = show . box . proofBlock


data Label = Lponens | Labs | Lpair | Lpi1 | Lpi2
           | Linr | Linl | Lcase | Lunit | Labort | Labsurd
           
instance Show Label where
  show Lponens = "(→)"
  show Labs = "(λ)"
  show Lpair = "(,)"
  show Lpi1 = "(π₁)"
  show Lpi2 = "(π₂)"
  show Linl = "(ιnl)"
  show Linr = "(ιnr)"
  show Lcase = "(Case)"
  show Lunit = "(★)"
  show Labort = "(□)"
  show Labsurd = "(■)"

type Depth = Int
type TermDiagram = (Exp,Depth,Type)


-- | Gets a type derivation diagram of the term.
-- It fails if the term is non-typeable.
gentzendiagram :: Exp -> Maybe (ProofTree String String)
gentzendiagram l = do
  (_, d)   <- typeinfer' variables 0 emptyctx l (Tvar 0)
  maintype <- typeinfer variables emptyctx l (Tvar 0) <*> pure (Tvar 0)
  let (normtemplate, _) = normalizeTemplate Map.empty 0 maintype
  return (bimap (showTermDiagram normtemplate) show d)
  where
    showTermDiagram normtemplate (expl, depth, t) =
      show (quicknameIndexes depth variableNames expl) ++
      " ∷ " ++
      show (applynormalization normtemplate t)

-- | Type inference algorithm. Infers a type from a given context and expression
-- with a set of constraints represented by a unifier type. The result type must
-- be unifiable with this given type.
-- Generalized version.
typeinfer' :: [Variable] -- ^ List of fresh variables
          -> Depth       -- ^ Lambda abstraction depth
          -> Context     -- ^ Type context
          -> Exp         -- ^ Lambda expression whose type has to be inferred
          -> Type        -- ^ Constraint
          -> Maybe (Substitution, ProofTree TermDiagram Label)
          
typeinfer' []  _ _ _ _ = Nothing
typeinfer' [_] _ _ _ _ = Nothing

typeinfer' _ depth ctx l@(Var n) b
   | Map.member n ctx = do
       var <- Map.lookup n ctx
       ss <- unify var b
       return (ss, Inference (l, depth, ss b))
   | otherwise  = Nothing

typeinfer' (x:vars) depth ctx l@(App p q) b = do
  (sigma, d1) <- typeinfer' (evens vars) depth ctx                  p (Arrow (Tvar x) b)
  (tau,   d2) <- typeinfer' (odds  vars) depth (applyctx sigma ctx) q (sigma (Tvar x))
  let ss = tau . sigma
  let fulld1 = bimap (\(d1e,d1d,d1t) -> (d1e,d1d,tau d1t)) id d1
  return (ss, Deduction (l, depth, ss b) Lponens [fulld1,d2])
  where
    odds [] = []
    odds [_] = []
    odds (_:e:xs) = e : odds xs
    evens [] = []
    evens [e] = [e]
    evens (e:_:xs) = e : evens xs


typeinfer' (a:x:vars) depth ctx l@(Lambda p) b = do
  sigma <- unify b (Arrow (Tvar a) (Tvar x))
  let nctx = applyctx sigma (Map.insert 1 (sigma $ Tvar a) (incrementindices ctx))
  (tau, d2) <- typeinfer' vars (succ depth) nctx p (sigma $ Tvar x)
  let ss = tau . sigma
  return (ss, Deduction (l, depth, ss b) Labs [d2])

typeinfer' (x:y:vars) depth ctx l@(Pair m n) a = do
  sigma <- unify a (Times (Tvar x) (Tvar y))
  (tau, d1) <- typeinfer' (evens vars) depth (applyctx sigma         ctx) m (sigma (Tvar x))
  (rho, d2) <- typeinfer' (odds  vars) depth (applyctx (tau . sigma) ctx) n (tau (sigma (Tvar y)))
  let ss = rho . tau . sigma
  let fulld1 = bimap (\(d1e,d1d,d1t) -> (d1e,d1d,rho d1t)) id d1
  return (ss, Deduction (l, depth, ss a) Lpair [fulld1,d2])
  where
    odds [] = []
    odds [_] = []
    odds (_:e:xs) = e : odds xs
    evens [] = []
    evens [e] = [e]
    evens (e:_:xs) = e : evens xs


typeinfer' (y:vars) depth ctx l@(Pi1 m) a = do
  (sigma, d1) <- typeinfer' vars depth ctx m (Times a (Tvar y))
  let ss = sigma
  return (ss, Deduction (l, depth, ss a) Lpi1 [d1])
  
typeinfer' (x:vars) depth ctx l@(Pi2 m) b = do
  (sigma, d1) <- typeinfer' vars depth ctx m (Times (Tvar x) b)
  let ss = sigma
  return (ss, Deduction (l, depth, ss b) Lpi2 [d1])

typeinfer' (x:y:vars) depth ctx l@(Inl m) a = do
  sigma <- unify a (Union (Tvar x) (Tvar y))
  (tau, d1) <- typeinfer' vars depth (applyctx sigma ctx) m (sigma (Tvar x))
  let ss = tau . sigma
  return (ss, Deduction (l, depth, ss a) Linl [d1])

typeinfer' (x:y:vars) depth ctx l@(Inr m) a = do
  sigma <- unify a (Union (Tvar x) (Tvar y))
  (tau, d1) <- typeinfer' vars depth (applyctx sigma ctx) m (sigma (Tvar y))
  let ss = tau . sigma
  return (ss, Deduction (l, depth, ss a) Linr [d1])

typeinfer' (x:y:vars) depth ctx l@(Caseof m f g) a = do
  (sigma, d1) <- typeinfer' (third1 vars) depth ctx                          f (Arrow (Tvar x) a)
  (tau,   d2) <- typeinfer' (third2 vars) depth (applyctx sigma ctx)         g (Arrow (sigma $ Tvar y) (sigma a))
  (rho,   d3) <- typeinfer' (third3 vars) depth (applyctx (tau . sigma) ctx) m (Union (tau . sigma $ Tvar x) (tau . sigma $ Tvar y))
  let ss = rho . tau . sigma
  let fulld1 = bimap (\(d1e,d1d,d1t) -> (d1e,d1d,(rho . tau) d1t)) id d1
  let fulld2 = bimap (\(d2e,d2d,d2t) -> (d2e,d2d,rho d2t)) id d2
  -- Pruning the tree to make it match the natural deduction case rule
  case fulld1 of
    Deduction _ Labs [reald1] ->
      case fulld2 of
        Deduction _ Labs [reald2] -> return (ss, Deduction (l, depth, ss a) Lcase [reald1,reald2,d3])
        _ -> Nothing
    _ -> Nothing
    
  where
    third1 [] = []
    third1 [_] = []
    third1 [_,_] = []
    third1 (_:_:e:xs) = e : third1 xs
    third2 [] = []
    third2 [_] = []
    third2 [_,e] = [e]
    third2 (_:e:_:xs) = e : third2 xs
    third3 [] = []
    third3 [e] = [e]
    third3 [e,_] = [e]
    third3 (e:_:_:xs) = e : third3 xs

typeinfer' _ depth _ l@Unit a = do
  ss <- unify Unitty a
  return (ss, Deduction (l, depth, ss a) Lunit [])

typeinfer' vars depth ctx l@(Abort m) a = do
  (ss, d1) <- typeinfer' vars depth ctx m Bottom
  return (ss, Deduction (l, depth, ss a) Labort [d1])

typeinfer' vars depth ctx l@(Absurd m) a = do
  sigma     <- unify Bottom a
  (tau, d1) <- typeinfer' vars depth (applyctx sigma ctx) m Bottom
  let ss = tau . sigma
  return (ss, Deduction (l, depth, ss a) Labsurd [d1])

                     
