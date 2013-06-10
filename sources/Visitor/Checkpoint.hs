-- Language extensions {{{
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}
-- }}}

module Visitor.Checkpoint where

-- Imports {{{
import Control.Exception (Exception(),throw)
import Control.Monad ((>=>))
import Control.Monad.Operational (ProgramViewT(..),viewT)

import Data.ByteString (ByteString)
import Data.Composition
import Data.Derive.Monoid
import Data.Derive.Serialize
import Data.DeriveTH
import Data.Functor.Identity (Identity,runIdentity)
import Data.Maybe (isJust)
import Data.Monoid ((<>),Monoid(..))
import Data.Sequence ((|>),Seq,viewr,ViewR(..))
import qualified Data.Sequence as Seq
import Data.Serialize
import Data.Typeable (Typeable)

import Visitor
import Visitor.Path
-- }}}

-- Types {{{

data Checkpoint = -- {{{
    CacheCheckpoint ByteString Checkpoint
  | ChoiceCheckpoint Checkpoint Checkpoint
  | Explored
  | Unexplored
  deriving (Eq,Ord,Read,Show)
$( derive makeSerialize ''Checkpoint )
-- }}}

type CheckpointCursor = Seq CheckpointDifferential

data CheckpointDifferential = -- {{{
    CacheCheckpointD ByteString
  | ChoiceCheckpointD Branch Checkpoint
  deriving (Eq,Read,Show)
-- }}}

type Context m α = Seq (ContextStep m α)

data ContextStep m α = -- {{{
    CacheContextStep ByteString
  | LeftBranchContextStep Checkpoint (TreeBuilderT m α)
  | RightBranchContextStep
-- }}}

type ContextUpdate m α = -- {{{
    Context m α →
    Maybe (Context m α, Checkpoint, TreeBuilderT m α)
-- }}}

data Progress α = Progress -- {{{
    {   progressCheckpoint :: Checkpoint
    ,   progressResult :: α
    } deriving (Eq,Show)
$( derive makeMonoid ''Progress )
$( derive makeSerialize ''Progress )
-- }}}

newtype ResultFetcher m α = ResultFetcher -- {{{
    {   fetchResult :: m (Maybe (α, Checkpoint, ResultFetcher m α))
    }
-- }}}

data FirstResultFetcher α = -- {{{
    DoneFetchingFirst (Maybe α)
  | StillFetchingFirst Checkpoint (FirstResultFetcher α)
-- }}}

newtype FirstResultFetcherT m α = FirstResultFetcherT -- {{{
    {   firstResultFetcher :: m (Either (Checkpoint, FirstResultFetcherT m α) (Maybe α))
    }
-- }}}

data FoundResultFetcher α β = -- {{{
    DoneFetchingFound (Either α β)
  | StillFetchingFound Checkpoint (FoundResultFetcher α β)
-- }}}

newtype FoundResultFetcherT m α β = FoundResultFetcherT -- {{{
    {   foundResultFetcher :: m (Either (Checkpoint, FoundResultFetcherT m α β) (Either α β))
    }
-- }}}

data VisitorTState m α = VisitorTState -- {{{
    {   visitorStateContext :: !(Context m α)
    ,   visitorStateCheckpoint :: !Checkpoint
    ,   visitorStateVisitor :: !(TreeBuilderT m α)
    }
-- }}}
type VisitorState = VisitorTState Identity

-- }}}

-- Exceptions {{{

data InconsistentCheckpoints = InconsistentCheckpoints Checkpoint Checkpoint deriving (Eq,Show,Typeable)

instance Exception InconsistentCheckpoints

-- }}}

-- Instances {{{

instance Functor Progress where
    fmap f (Progress checkpoint result) = Progress checkpoint (f result)

instance Monoid Checkpoint where -- {{{
    mempty = Unexplored
    Explored `mappend` _ = Explored
    _ `mappend` Explored = Explored
    Unexplored `mappend` x = x
    x `mappend` Unexplored = x
    (ChoiceCheckpoint lx rx) `mappend` (ChoiceCheckpoint ly ry) =
        mergeCheckpointRoot (ChoiceCheckpoint (lx `mappend` ly) (rx `mappend` ry))
    (CacheCheckpoint cx x) `mappend` (CacheCheckpoint cy y)
      | cx == cy = mergeCheckpointRoot (CacheCheckpoint cx (x `mappend` y))
    mappend x y = throw (InconsistentCheckpoints x y)
-- }}}

instance Show (ContextStep m α) where -- {{{
    show (CacheContextStep c) = "CacheContextStep[" ++ show c ++ "]"
    show (LeftBranchContextStep checkpoint _) = "LeftBranchContextStep(" ++ show checkpoint ++ ")"
    show RightBranchContextStep = "RightRightBranchContextStep"
-- }}}

-- }}}

-- Functions {{{

checkpointFromContext :: Context m α → Checkpoint → Checkpoint -- {{{
checkpointFromContext = checkpointFromSequence $
    \step → case step of
        CacheContextStep cache → CacheCheckpoint cache
        LeftBranchContextStep right_checkpoint _ → flip ChoiceCheckpoint right_checkpoint
        RightBranchContextStep → ChoiceCheckpoint Explored
-- }}}

checkpointFromCursor :: CheckpointCursor → Checkpoint → Checkpoint -- {{{
checkpointFromCursor = checkpointFromSequence $
    \step → case step of
        CacheCheckpointD cache → CacheCheckpoint cache
        ChoiceCheckpointD LeftBranch right_checkpoint → flip ChoiceCheckpoint right_checkpoint
        ChoiceCheckpointD RightBranch left_checkpoint → ChoiceCheckpoint left_checkpoint
-- }}}

checkpointFromInitialPath :: Path → Checkpoint → Checkpoint -- {{{
checkpointFromInitialPath = checkpointFromSequence $
    \step → case step of
        CacheStep c → CacheCheckpoint c
        ChoiceStep LeftBranch → flip ChoiceCheckpoint Unexplored
        ChoiceStep RightBranch → ChoiceCheckpoint Unexplored
-- }}}

checkpointFromSequence :: -- {{{
    (α → (Checkpoint → Checkpoint)) →
    Seq α →
    Checkpoint →
    Checkpoint
checkpointFromSequence processStep sequence =
    case viewr sequence of
        EmptyR → id
        rest :> step →
            checkpointFromSequence processStep rest
            .
            mergeCheckpointRoot
            .
            processStep step
-- }}}

checkpointFromVisitorState :: VisitorTState m α → Checkpoint -- {{{
checkpointFromVisitorState VisitorTState{..} =
    checkpointFromContext visitorStateContext visitorStateCheckpoint
-- }}}

checkpointFromUnexploredPath :: Path → Checkpoint -- {{{
checkpointFromUnexploredPath path = checkpointFromSequence
    (\step → case step of
        CacheStep c → CacheCheckpoint c
        ChoiceStep LeftBranch → flip ChoiceCheckpoint Explored
        ChoiceStep RightBranch → ChoiceCheckpoint Explored
    )
    path
    Unexplored
-- }}}

fetchFirstResult :: FirstResultFetcher α → Maybe α -- {{{
fetchFirstResult (DoneFetchingFirst maybe_result) = maybe_result
fetchFirstResult (StillFetchingFirst _ next_fetcher) = fetchFirstResult next_fetcher
-- }}}

fetchFirstResultT :: Monad m ⇒ FirstResultFetcherT m α → m (Maybe α) -- {{{
fetchFirstResultT = firstResultFetcher >=> either (fetchFirstResultT . snd) return
-- }}}

fetchFoundResult :: FoundResultFetcher α β → Either α β -- {{{
fetchFoundResult (DoneFetchingFound maybe_result) = maybe_result
fetchFoundResult (StillFetchingFound _ next_fetcher) = fetchFoundResult next_fetcher
-- }}}

fetchFoundResultT :: Monad m ⇒ FoundResultFetcherT m α β → m (Either α β) -- {{{
fetchFoundResultT = foundResultFetcher >=> either (fetchFoundResultT . snd) return
-- }}}

gatherResults :: -- {{{
    (Monad m, Monoid α) ⇒
    ResultFetcher m α →
    m α
gatherResults = go mempty
  where
    go result =
        fetchResult
        >=>
        maybe
            (return result)
            (\(result,_,fetcher) → go result fetcher)
-- }}}

initialVisitorState :: Checkpoint → TreeBuilderT m α → VisitorTState m α -- {{{
initialVisitorState = VisitorTState Seq.empty
-- }}}

invertCheckpoint :: Checkpoint → Checkpoint -- {{{
invertCheckpoint Explored = Unexplored
invertCheckpoint Unexplored = Explored
invertCheckpoint (CacheCheckpoint cache rest) =
    mergeCheckpointRoot (CacheCheckpoint cache (invertCheckpoint rest))
invertCheckpoint (ChoiceCheckpoint left right) =
    mergeCheckpointRoot (ChoiceCheckpoint (invertCheckpoint left) (invertCheckpoint right))
-- }}}

mergeAllCheckpointNodes :: Checkpoint → Checkpoint -- {{{
mergeAllCheckpointNodes (ChoiceCheckpoint left right) = mergeCheckpointRoot (ChoiceCheckpoint (mergeAllCheckpointNodes left) (mergeAllCheckpointNodes right))
mergeAllCheckpointNodes (CacheCheckpoint cache checkpoint) = mergeCheckpointRoot (CacheCheckpoint cache (mergeAllCheckpointNodes checkpoint))
mergeAllCheckpointNodes checkpoint = checkpoint
-- }}}

mergeCheckpointRoot :: Checkpoint → Checkpoint -- {{{
mergeCheckpointRoot (ChoiceCheckpoint Unexplored Unexplored) = Unexplored
mergeCheckpointRoot (ChoiceCheckpoint Explored Explored) = Explored
mergeCheckpointRoot (CacheCheckpoint _ Explored) = Explored
mergeCheckpointRoot checkpoint = checkpoint
-- }}}

pathFromContext :: Context m α → Path -- {{{
pathFromContext = fmap pathStepFromContextStep
-- }}}

pathFromCursor :: CheckpointCursor → Path -- {{{
pathFromCursor = fmap pathStepFromCursorDifferential
-- }}}

pathStepFromContextStep :: ContextStep m α → Step -- {{{
pathStepFromContextStep (CacheContextStep cache) = CacheStep cache
pathStepFromContextStep (LeftBranchContextStep _ _) = ChoiceStep LeftBranch
pathStepFromContextStep (RightBranchContextStep) = ChoiceStep RightBranch
-- }}}

pathStepFromCursorDifferential :: CheckpointDifferential → Step -- {{{
pathStepFromCursorDifferential (CacheCheckpointD cache) = CacheStep cache
pathStepFromCursorDifferential (ChoiceCheckpointD active_branch _) = ChoiceStep active_branch
-- }}}

visitTreeStartingFromCheckpoint :: -- {{{
    Monoid α ⇒
    Checkpoint →
    TreeBuilder α →
    α
visitTreeStartingFromCheckpoint = runIdentity .* visitTreeTStartingFromCheckpoint
-- }}}

visitTreeTStartingFromCheckpoint :: -- {{{
    (Monad m, Monoid α) ⇒
    Checkpoint →
    TreeBuilderT m α →
    m α
visitTreeTStartingFromCheckpoint = go mempty .* initialVisitorState
  where
    go !accum =
        stepThroughTreeTStartingFromCheckpoint
        >=>
        \(maybe_solution,maybe_new_visitor_state) →
            let new_accum = maybe id (flip mappend) maybe_solution accum
            in maybe (return new_accum) (go new_accum) maybe_new_visitor_state
{-# INLINE visitTreeTStartingFromCheckpoint #-}
-- }}}

visitTreeUntilFirstStartingFromCheckpoint :: -- {{{
    Checkpoint →
    TreeBuilder α →
    Maybe α
visitTreeUntilFirstStartingFromCheckpoint = runIdentity .* visitTreeTUntilFirstStartingFromCheckpoint
-- }}}

visitTreeTUntilFirstStartingFromCheckpoint :: -- {{{
    Monad m ⇒
    Checkpoint →
    TreeBuilderT m α →
    m (Maybe α)
visitTreeTUntilFirstStartingFromCheckpoint = go .* initialVisitorState
  where
    go = stepThroughTreeTStartingFromCheckpoint
         >=>
         \(maybe_solution,maybe_new_visitor_state) →
            case maybe_solution of
                Just _ → return maybe_solution
                Nothing → maybe (return Nothing) go maybe_new_visitor_state
{-# INLINE visitTreeTUntilFirstStartingFromCheckpoint #-}
-- }}}

visitTreeUntilFoundStartingFromCheckpoint :: -- {{{
    Monoid α ⇒
    (α → Maybe β) →
    Checkpoint →
    TreeBuilder α →
    Either α β
visitTreeUntilFoundStartingFromCheckpoint = runIdentity .** visitTreeTUntilFoundStartingFromCheckpoint
-- }}}

visitTreeTUntilFoundStartingFromCheckpoint :: -- {{{
    (Monad m, Monoid α) ⇒
    (α → Maybe β) →
    Checkpoint →
    TreeBuilderT m α →
    m (Either α β)
visitTreeTUntilFoundStartingFromCheckpoint f = go mempty .* initialVisitorState
  where
    go accum =
        stepThroughTreeTStartingFromCheckpoint
        >=>
        \(maybe_solution,maybe_new_visitor_state) →
            case maybe_solution of
                Nothing → maybe (return (Left accum)) (go accum) maybe_new_visitor_state
                Just solution →
                    let new_accum = accum <> solution
                    in case f new_accum of
                        Nothing → maybe (return (Left new_accum)) (go new_accum) maybe_new_visitor_state
                        Just result → return (Right result)
{-# INLINE visitTreeTUntilFoundStartingFromCheckpoint #-}
-- }}}

stepThroughTreeStartingFromCheckpoint :: -- {{{
    VisitorState α →
    (Maybe α,Maybe (VisitorState α))
stepThroughTreeStartingFromCheckpoint = runIdentity . stepThroughTreeTStartingFromCheckpoint
-- }}}

stepThroughTreeTStartingFromCheckpoint :: -- {{{
    Monad m ⇒
    VisitorTState m α →
    m (Maybe α,Maybe (VisitorTState m α))
stepThroughTreeTStartingFromCheckpoint (VisitorTState context checkpoint visitor) = case checkpoint of
    Explored → return (Nothing, moveUpContext)
    Unexplored → getView >>= \view → case view of
        Return x → return (Just x, moveUpContext)
        Null :>>= _ → return (Nothing, moveUpContext)
        Cache mx :>>= k →
            mx >>= return . maybe
                (Nothing, moveUpContext)
                (\x → (Nothing, Just $
                    VisitorTState
                        (context |> CacheContextStep (encode x))
                        Unexplored
                        (TreeBuilderT . k $ x)
                ))
        Choice left right :>>= k → return
            (Nothing, Just $
                VisitorTState
                    (context |> LeftBranchContextStep Unexplored (right >>= TreeBuilderT . k))
                    Unexplored
                    (left >>= TreeBuilderT . k)
            )
    CacheCheckpoint cache rest_checkpoint → getView >>= \view → case view of
        Cache _ :>>= k → return
            (Nothing, Just $
                VisitorTState
                    (context |> CacheContextStep cache)
                    rest_checkpoint
                    (either error (TreeBuilderT . k) . decode $ cache)
            )
        _ → throw PastVisitorIsInconsistentWithPresentVisitor
    ChoiceCheckpoint left_checkpoint right_checkpoint →  getView >>= \view → case view of
        Choice left right :>>= k → return
            (Nothing, Just $
                VisitorTState
                    (context |> LeftBranchContextStep right_checkpoint (right >>= TreeBuilderT . k))
                    left_checkpoint
                    (left >>= TreeBuilderT . k)
            )
        _ → throw PastVisitorIsInconsistentWithPresentVisitor
  where
    getView = viewT . unwrapTreeBuilderT $ visitor
    moveUpContext = go context
      where
        go context = case viewr context of
            EmptyR → Nothing
            rest_context :> LeftBranchContextStep right_checkpoint right_visitor →
                Just (VisitorTState
                        (rest_context |> RightBranchContextStep)
                        right_checkpoint
                        right_visitor
                     )
            rest_context :> _ → go rest_context
{-# INLINE stepThroughTreeTStartingFromCheckpoint #-}
-- }}}

walkThroughTree :: -- {{{
    Monoid α ⇒
    TreeBuilder α →
    [(α,Checkpoint)]
walkThroughTree = walkThroughTreeStartingFromCheckpoint Unexplored
-- }}}

walkThroughTreeT :: -- {{{
    (Monad m, Monoid α) ⇒
    TreeBuilderT m α →
    ResultFetcher m α
walkThroughTreeT = walkThroughTreeTStartingFromCheckpoint Unexplored
{-# INLINE walkThroughTreeT #-}
-- }}}

walkThroughTreeUntilFirst :: -- {{{
    TreeBuilder α →
    FirstResultFetcher α
walkThroughTreeUntilFirst = walkThroughTreeUntilFirstStartingFromCheckpoint Unexplored
-- }}}

walkThroughTreeTUntilFirst :: -- {{{
    Monad m ⇒
    TreeBuilderT m α →
    FirstResultFetcherT m α
walkThroughTreeTUntilFirst = walkThroughTreeTUntilFirstStartingFromCheckpoint Unexplored
-- }}}

walkThroughTreeStartingFromCheckpoint :: -- {{{
    Monoid α ⇒
    Checkpoint →
    TreeBuilder α →
    [(α,Checkpoint)]
walkThroughTreeStartingFromCheckpoint = go1 .* walkThroughTreeTStartingFromCheckpoint
  where
    go1 (runIdentity . fetchResult → Just (next_accum,checkpoint,next_result)) = go3 next_accum checkpoint next_result
    go1 _ = [(mempty,Explored)]

    go2 (runIdentity . fetchResult → Just (next_accum,checkpoint,next_result)) = go3 next_accum checkpoint next_result
    go2 _ = []

    go3 next_accum checkpoint !next_result = (next_accum,checkpoint):go2 next_result
-- }}}

walkThroughTreeTStartingFromCheckpoint :: -- {{{
    ∀ m α. (Monad m, Monoid α) ⇒
    Checkpoint →
    TreeBuilderT m α →
    ResultFetcher m α
walkThroughTreeTStartingFromCheckpoint = go mempty .* initialVisitorState
  where
    go :: α → VisitorTState m α → ResultFetcher m α
    go accum visitor_state = ResultFetcher $
        stepThroughTreeTStartingFromCheckpoint visitor_state
        >>=
        \(maybe_solution,maybe_new_state) → return $
            let !new_accum = maybe id (flip mappend) maybe_solution accum
            in Just $ case maybe_new_state of
                Nothing → (new_accum,Explored,ResultFetcher (return Nothing))
                Just new_state →
                    (new_accum
                    ,checkpointFromVisitorState new_state
                    ,go new_accum new_state
                    )
{-# INLINE walkThroughTreeTStartingFromCheckpoint #-}
-- }}}

walkThroughTreeUntilFirstStartingFromCheckpoint :: -- {{{
    Checkpoint →
    TreeBuilder α →
    FirstResultFetcher α
walkThroughTreeUntilFirstStartingFromCheckpoint = go .* initialVisitorState
  where
    go visitor_state
      | isJust maybe_solution = DoneFetchingFirst maybe_solution
      | otherwise =
         case maybe_new_state of
            Nothing → DoneFetchingFirst Nothing
            Just new_state →
                StillFetchingFirst
                    (checkpointFromVisitorState new_state)
                    (go new_state)
      where
        (maybe_solution,maybe_new_state) = stepThroughTreeStartingFromCheckpoint visitor_state
-- }}}

walkThroughTreeTUntilFirstStartingFromCheckpoint :: -- {{{
    Monad m ⇒
    Checkpoint →
    TreeBuilderT m α →
    FirstResultFetcherT m α
walkThroughTreeTUntilFirstStartingFromCheckpoint = go .* initialVisitorState
  where
    go visitor_state = FirstResultFetcherT $
        stepThroughTreeTStartingFromCheckpoint visitor_state
        >>=
        \(maybe_solution,maybe_new_state) → return $
            case maybe_solution of
                Just _ → Right maybe_solution
                Nothing →
                    case maybe_new_state of
                        Nothing → Right Nothing
                        Just new_state →
                            Left
                            $
                            (checkpointFromVisitorState new_state
                            ,go new_state
                            )
{-# INLINE walkThroughTreeTUntilFirstStartingFromCheckpoint #-}
-- }}}

walkThroughTreeUntilFoundStartingFromCheckpoint :: -- {{{
    Monoid α ⇒
    (α → Maybe β) →
    Checkpoint →
    TreeBuilder α →
    FoundResultFetcher α β
walkThroughTreeUntilFoundStartingFromCheckpoint f = go mempty .* initialVisitorState
  where
    go result visitor_state =
        case maybe_solution of
            Just solution →
                let new_result = result <> solution
                in case f new_result of
                    Just x → DoneFetchingFound (Right x)
                    Nothing → continueWith new_result
            Nothing → continueWith result
      where
        (maybe_solution,maybe_new_state) = stepThroughTreeStartingFromCheckpoint visitor_state

        continueWith current_result =
            case maybe_new_state of
                Nothing → DoneFetchingFound (Left current_result)
                Just new_state →
                    StillFetchingFound
                        (checkpointFromVisitorState new_state)
                        (go current_result new_state)
-- }}}

walkThroughTreeTUntilFoundStartingFromCheckpoint :: -- {{{
    (Monoid α, Monad m) ⇒
    (α → Maybe β) →
    Checkpoint →
    TreeBuilderT m α →
    FoundResultFetcherT m α β
walkThroughTreeTUntilFoundStartingFromCheckpoint f = go mempty .* initialVisitorState
  where
    go result visitor_state = FoundResultFetcherT $ do
        (maybe_solution,maybe_new_state) ← stepThroughTreeTStartingFromCheckpoint visitor_state
        let continueWith current_result =
                case maybe_new_state of
                    Nothing → (Right . Left $ current_result)
                    Just new_state →
                        Left
                        $
                        (checkpointFromVisitorState new_state
                        ,go current_result new_state
                        )
        return $
            case maybe_solution of
                Nothing → continueWith result
                Just solution →
                    let new_result = result <> solution
                    in case f new_result of
                        Just x → (Right . Right $ x)
                        Nothing → continueWith new_result
{-# INLINE walkThroughTreeTUntilFoundStartingFromCheckpoint #-}
-- }}}

-- }}}