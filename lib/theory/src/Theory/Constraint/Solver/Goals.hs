{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns  #-}
-- |
-- Copyright   : (c) 2010-2012 Benedikt Schmidt & Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- The constraint reduction rules, which are not enforced as invariants in
-- "Theory.Constraint.Solver.Reduction".
--
-- A goal represents a possible application of a rule that may result in
-- multiple cases or even non-termination (if applied repeatedly). These goals
-- are computed as the list of 'openGoals'. See
-- "Theory.Constraint.Solver.ProofMethod" for the public interface to solving
-- goals and the implementation of heuristics.
module Theory.Constraint.Solver.Goals (
    Usefulness(..)
  , AnnotatedGoal
  , openGoals
  , solveGoal
  ) where

import           Prelude                                 hiding (id, (.))

import qualified Data.DAG.Simple                         as D (cyclic)
import           Data.Foldable                           (foldMap)
import qualified Data.Map                                as M
import qualified Data.Monoid                             as Mono
import qualified Data.Set                                as S

import           Control.Basics
import           Control.Category
import           Control.Monad.Disj
import           Control.Monad.State                     (gets)

import           Extension.Data.Label

import           Theory.Constraint.Solver.Contradictions (substCreatesNonNormalTerms)
import           Theory.Constraint.Solver.Reduction
import           Theory.Constraint.Solver.Types
import           Theory.Constraint.System
import           Theory.Model


------------------------------------------------------------------------------
-- Extracting Goals
------------------------------------------------------------------------------

data Usefulness =
    Useful
  -- ^ A goal that is likely to result in progress.
  | LoopBreaker
  -- ^ A goal that is delayed to avoid immediate termination.
  | ProbablyConstructible
  -- ^ A goal that is likely to be constructible by the adversary.
  | CurrentlyDeducible
  -- ^ A message that is deducible for the current solution.
  deriving (Show, Eq, Ord)

-- | Goals annotated with their number and usefulness.
type AnnotatedGoal = (Goal, (Integer, Usefulness))


-- Instances
------------

-- | The list of goals that must be solved before a solution can be extracted.
-- Each goal is annotated with its age and an indicator for its usefulness.
openGoals :: System -> [AnnotatedGoal]
openGoals sys = do
    (goal, status) <- M.toList $ get sGoals sys
    let solved = get gsSolved status
    -- check whether the goal is still open
    guard $ case goal of
        ActionG _ (kFactView -> Just (UpK, m)) ->
          not $    solved
                || isMsgVar m || sortOfLNTerm m == LSortPub
                -- handled by 'insertAction'
                || isPair m || isInverse m || isProduct m
                || isNullaryFunction m
        ActionG _ _                               -> not solved
        PremiseG _ _                              -> not solved
        -- Technically the 'False' disj would be a solvable goal. However, we
        -- have a separate proof method for this, i.e., contradictions.
        DisjG (Disj [])                           -> False
        DisjG _                                   -> not solved

        ChainG c _     ->
          case kFactView (nodeConcFact c sys) of
              Just (DnK,  m) | isMsgVar m -> False
                             | otherwise  -> not solved
              fa -> error $ "openChainGoals: impossible fact: " ++ show fa

        -- FIXME: Split goals may be duplicated, we always have to check
        -- explicitly if they still exist.
        SplitG idx -> splitExists (get sEqStore sys) idx

    let
        useful = case goal of
          _ | get gsLoopBreaker status              -> LoopBreaker
          ActionG i (kFactView -> Just (UpK, m))
              -- if there are KU-guards then all knowledge goals are useful
            | hasKUGuards             -> Useful
            | currentlyDeducible i m  -> CurrentlyDeducible
            | probablyConstructible m -> ProbablyConstructible
          _                           -> Useful

    return (goal, (get gsNr status, useful))
  where
    existingDeps = rawLessRel sys
    hasKUGuards  =
        any ((KUFact `elem`) . guardFactTags) $ S.toList $ get sFormulas sys

    checkTermLits :: (LSort -> Bool) -> LNTerm -> Bool
    checkTermLits p =
        Mono.getAll . foldMap (Mono.All . p . sortOfLit)
      where
        sortOfLit (Con n) = sortOfName n
        sortOfLit (Var v) = lvarSort v

    -- KU goals of messages that are likely to be constructible by the
    -- adversary. These are terms that do not contain a fresh name or a fresh
    -- name variable. For protocols without loops they are very likely to be
    -- constructible. For protocols with loops, such terms have to be given
    -- similar priority as loop-breakers.
    probablyConstructible  = checkTermLits (LSortFresh /=)

    -- KU goals of messages that are currently deducible. Either because they
    -- are composed of public names only or because they can be extracted from
    -- a sent message using unpairing or inversion only.
    currentlyDeducible i m = checkTermLits (LSortPub ==) m || extractible i m

    extractible i m = or $ do
        (j, ru) <- M.toList $ get sNodes sys
        -- We cannot deduce a message from a last node.
        guard (not $ isLast sys j)
        let derivedMsgs = concatMap toplevelTerms $
                [ t | Fact OutFact [t] <- get rConcs ru] <|>
                [ t | Just (DnK, t)    <- kFactView <$> get rConcs ru]
        -- m is deducible from j without an immediate contradiction
        -- if it is a derived message of 'ru' and the dependency does
        -- not make the graph cyclic.
        return $ m `elem` derivedMsgs &&
                 not (D.cyclic ((j, i) : existingDeps))

    toplevelTerms t@(destPair -> Just (t1, t2)) =
        t : toplevelTerms t1 ++ toplevelTerms t2
    toplevelTerms t@(destInverse -> Just t1) = t : toplevelTerms t1
    toplevelTerms t = [t]




------------------------------------------------------------------------------
-- Solving 'Goal's
------------------------------------------------------------------------------

-- | @solveGoal rules goal@ enumerates all possible cases of how this goal
-- could be solved in the context of the given @rules@. For each case, a
-- sensible case-name is returned.
solveGoal :: Goal -> Reduction String
solveGoal goal = do
    -- mark before solving, as representation might change due to unification
    markGoalAsSolved "directly" goal
    rules <- askM pcRules
    case goal of
      ActionG i fa  -> solveAction  (nonSilentRules rules) (i, fa)
      PremiseG p fa ->
           solvePremise (get crProtocol rules ++ get crConstruct rules) p fa
      ChainG c p    -> solveChain (get crDestruct  rules) (c, p)
      SplitG i      -> solveSplit i
      DisjG disj    -> solveDisjunction disj

-- The follwoing functions are internal to 'solveGoal'. Use them with great
-- care.

-- | CR-rule *S_at*: solve an action goal.
solveAction :: [RuleAC]          -- ^ All rules labelled with an action
            -> (NodeId, LNFact)  -- ^ The action we are looking for.
            -> Reduction String  -- ^ A sensible case name.
solveAction rules (i, fa) = do
    mayRu <- M.lookup i <$> getM sNodes
    showRuleCaseName <$> case mayRu of
        Nothing -> do ru  <- labelNodeId i rules
                      act <- disjunctionOfList $ get rActs ru
                      void (solveFactEqs SplitNow [Equal fa act])
                      return ru

        Just ru -> do unless (fa `elem` get rActs ru) $ do
                          act <- disjunctionOfList $ get rActs ru
                          void (solveFactEqs SplitNow [Equal fa act])
                      return ru

-- | CR-rules *DG_{2,P}* and *DG_{2,d}*: solve a premise with a direct edge
-- from a unifying conclusion or using a destruction chain.
--
-- Note that *In*, *Fr*, and *KU* facts are solved directly when adding a
-- 'ruleNode'.
--
solvePremise :: [RuleAC]       -- ^ All rules with a non-K-fact conclusion.
             -> NodePrem       -- ^ Premise to solve.
             -> LNFact         -- ^ Fact required at this premise.
             -> Reduction String -- ^ Case name to use.
solvePremise rules p faPrem
  | isKDFact faPrem = do
      iLearn    <- freshLVar "vl" LSortNode
      mLearn    <- varTerm <$> freshLVar "t" LSortMsg
      let concLearn = kdFact mLearn
          premLearn = outFact mLearn
          -- !! Make sure that you construct the correct rule!
          ruLearn = Rule (IntrInfo IRecvRule) [premLearn] [concLearn] []
          cLearn = (iLearn, ConcIdx 0)
          pLearn = (iLearn, PremIdx 0)
      modM sNodes  (M.insert iLearn ruLearn)
      insertChain cLearn p
      solvePremise rules pLearn premLearn

  | otherwise = do
      (ru, c, faConc) <- insertFreshNodeConc rules
      insertEdges [(c, faConc, faPrem, p)]
      return $ showRuleCaseName ru

-- | CR-rule *DG2_chain*: solve a chain constraint.
solveChain :: [RuleAC]              -- ^ All destruction rules.
           -> (NodeConc, NodePrem)  -- ^ The chain to extend by one step.
           -> Reduction String      -- ^ Case name to use.
solveChain rules (c, p) = do
    faConc  <- gets $ nodeConcFact c
    (do -- solve it by a direct edge
        faPrem <- gets $ nodePremFact p
        insertEdges [(c, faConc, faPrem, p)]
        let m = case kFactView faConc of
                  Just (DnK, m') -> m'
                  _              -> error $ "solveChain: impossible"
            caseName (viewTerm -> FApp o _) = showFunSymName o
            caseName t                      = show t
        return $ caseName m
     `disjunction`
     do -- extend it with one step
        cRule <- gets $ nodeRule (nodeConcNode c)
        (i, ru)     <- insertFreshNode rules
        -- contradicts normal form condition:
        -- no edge from dexp to dexp KD premise
        -- (this condition replaces the exp/noexp tags)
        contradictoryIf (isDexpRule cRule && isDexpRule ru)
        (v, faPrem) <- disjunctionOfList $ enumPrems ru
        insertEdges [(c, faConc, faPrem, (i, v))]
        markGoalAsSolved "directly" (PremiseG (i, v) faPrem)
        insertChain (i, ConcIdx 0) p
        return $ showRuleCaseName ru
     )
  where
    isDexpRule ru = case get rInfo ru of
        IntrInfo (DestrRule n) | n == expSymString -> True
        _                                          -> False

-- | Solve an equation split. There is no corresponding CR-rule in the rule
-- system on paper because there we eagerly split over all variants of a rule.
-- In practice, this is too expensive and we therefore use the equation store
-- to delay these splits.
solveSplit :: SplitId -> Reduction String
solveSplit x = do
    split <- gets ((`performSplit` x) . get sEqStore)
    let errMsg = error "solveSplit: inexistent split-id"
    store      <- maybe errMsg disjunctionOfList split
    -- FIXME: Simplify this interaction with the equation store
    hnd        <- getMaudeHandle
    substCheck <- gets (substCreatesNonNormalTerms hnd)
    store'     <- simp hnd substCheck store
    contradictoryIf (eqsIsFalse store')
    sEqStore =: store'
    return "split"

-- | CR-rule *S_disj*: solve a disjunction of guarded formulas using a case
-- distinction.
--
-- In contrast to the paper, we use n-ary disjunctions and also split over all
-- of them at once.
solveDisjunction :: Disj LNGuarded -> Reduction String
solveDisjunction disj = do
    (i, gfm) <- disjunctionOfList $ zip [(1::Int)..] $ getDisj disj
    insertFormula gfm
    return $ "case_" ++ show i
