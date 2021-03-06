{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}

{-| This module contains the infrastructure used to maintain a checkpoint during
    a tree exploration.
 -}
module LogicGrowsOnTrees.Checkpoint
    (
    -- * Types
      Checkpoint(..)
    , Progress(..)
    -- ** Cursors and contexts
    -- $cursors
    , CheckpointCursor
    , CheckpointDifferential(..)
    , Context
    , ContextStep(..)
    -- ** Exploration state
    , ExplorationTState(..)
    , ExplorationState
    , initialExplorationState
    -- * Exceptions
    , InconsistentCheckpoints(..)
    -- * Utility functions
    -- ** Checkpoint construction
    , checkpointFromContext
    , checkpointFromCursor
    , checkpointFromExplorationState
    , checkpointFromReversedList
    , checkpointFromSequence
    , checkpointFromInitialPath
    , checkpointFromUnexploredPath
    , simplifyCheckpointRoot
    , simplifyCheckpoint
    -- ** Path construction
    , pathFromContext
    , pathFromCursor
    , pathStepFromContextStep
    , pathStepFromCursorDifferential
    -- ** Miscelaneous
    , invertCheckpoint
    -- * Stepper functions
    -- $stepper
    , stepThroughTreeStartingFromCheckpoint
    , stepThroughTreeTStartingFromCheckpoint
    -- * Exploration functions
    -- $exploration
    , exploreTreeStartingFromCheckpoint
    , exploreTreeTStartingFromCheckpoint
    , exploreTreeUntilFirstStartingFromCheckpoint
    , exploreTreeTUntilFirstStartingFromCheckpoint
    , exploreTreeUntilFoundStartingFromCheckpoint
    , exploreTreeTUntilFoundStartingFromCheckpoint
    ) where

import Control.Exception (Exception(),throw)
import Control.DeepSeq (NFData)
import Control.Monad ((>=>))
import Control.Monad.Operational (ProgramViewT(..),viewT)

import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity,runIdentity)
import Data.Semigroup (Semigroup(..))
import Data.Monoid (Monoid(..))
import Data.Sequence (Seq,viewr,ViewR(..))
import qualified Data.Sequence as Seq
import Data.Serialize
import Data.Typeable (Typeable)

import Flow ((|>))

import GHC.Generics (Generic)

import LogicGrowsOnTrees
import LogicGrowsOnTrees.Path

--------------------------------------------------------------------------------
--------------------------------- Exceptions -----------------------------------
--------------------------------------------------------------------------------

{-| This exception is thrown when one attempts to merge checkpoints that
    disagree with each other; this will never happen as long as you only merge
    checkpoints that came from the same tree, so if you get this
    exception then there is almost certainly a bug in your code.
 -}
data InconsistentCheckpoints = InconsistentCheckpoints Checkpoint Checkpoint deriving (Eq,Show,Typeable)

instance Exception InconsistentCheckpoints

--------------------------------------------------------------------------------
----------------------------------- Types --------------------------------------
--------------------------------------------------------------------------------

{-| Information about the parts of a tree that have been explored. -}
data Checkpoint =
    CachePoint ByteString Checkpoint
  | ChoicePoint Checkpoint Checkpoint
  | Explored
  | Unexplored
  deriving (Eq,Generic,Ord,Read,Show)
instance NFData Checkpoint
instance Serialize Checkpoint

-- Note:  This function is not in the same place where it appears in the documentation.
{-| Simplifies the root of the checkpoint by replacing

    * @Choicepoint Unexplored Unexplored@ with @Unexplored@;

    * @Choicepoint Explored Explored@ with @Explored@; and

    * @CachePoint _ Explored@ with @Explored@.
 -}
simplifyCheckpointRoot :: Checkpoint → Checkpoint
simplifyCheckpointRoot (ChoicePoint Unexplored Unexplored) = Unexplored
simplifyCheckpointRoot (ChoicePoint Explored Explored) = Explored
simplifyCheckpointRoot (CachePoint _ Explored) = Explored
simplifyCheckpointRoot checkpoint = checkpoint

{-| The 'Monoid' instance is designed to take checkpoints from two different
    explorations of a given tree and merge them together to obtain a
    checkpoint that indicates /all/ of the areas that have been explored by
    anyone so far. For example, if the two checkpoints are @ChoicePoint Explored
    Unexplored@ and @ChoicePoint Unexplored (ChoicePoint Explored Unexplored)@
    then the result will be @ChoicePoint Explored (ChoicePoint Explored
    Unexplored)@.

    WARNING: This 'Semigroup' instance is a /partial/ function that expects
    checkpoints that have come from the /same/ tree; if this
    precondition is not met then if you are lucky it will notice the
    inconsistency and throw an exception to let you know that something is wrong
    and if you are not then it will silently give you a nonsense result. You are
    /very/ unlikely to run into this problem unless for some reason you are
    juggling multiple trees and have mixed up which checkpoint goes with which,
    which is something that is neither done nor encouraged in this package.
 -}
instance Semigroup Checkpoint where
    Explored <> _ = Explored
    _ <> Explored = Explored
    Unexplored <> x = x
    x <> Unexplored = x
    ChoicePoint lx rx <> ChoicePoint ly ry =
        simplifyCheckpointRoot $ ChoicePoint (lx <> ly) (rx <> ry)
    CachePoint cx x <> CachePoint cy y
      | cx == cy = simplifyCheckpointRoot $ CachePoint cx (x <> y)
    x <> y = throw $ InconsistentCheckpoints x y

instance Monoid Checkpoint where
    mempty = Unexplored

{-| Information about both the current checkpoint and the results we have
    gathered so far.
 -}
data Progress α = Progress
    {   progressCheckpoint :: Checkpoint
    ,   progressResult :: α
    } deriving (Eq,Functor,Generic,Show)
instance NFData α ⇒ NFData (Progress α)
instance Serialize α ⇒ Serialize (Progress α)

instance Semigroup α ⇒ Semigroup (Progress α) where
  Progress c1 r1 <> Progress c2 r2 = Progress (c1 <> c2) (r1 <> r2)

instance Monoid α ⇒ Monoid (Progress α) where
  mempty = Progress mempty mempty

---------------------------- Cursors and contexts ------------------------------

{- $cursors
The types in this subsection are essentially two kinds of zippers for the
'Checkpoint' type; as we explore a tree they represent where we are and how how
to backtrack. The difference between the two types that do this is that, at each
branch, 'Context' keeps around the subtree for the other branch whereas
'CheckpointCursor' does not. The reason for there being two different types is
workload stealing; specifically, when a branch has been stolen from us we want
to forget about its subtree because we are no longer going to explore that
branch ourselves; thus, workload stealing converts 'ContextStep's to
'CheckpointDifferential's. Put another way, as a worker (implemented in
"LogicGrowsOnTrees.Parallel.Common.Worker") explores the tree at all times it
has a 'CheckpointCursor' which tells us about the decisions that it made which
are /frozen/ as we will never backtrack into them to explore the other branch
and a 'Context' which tells us about where we need to backtrack to explore the
rest of the workload assigned to us.
 -}

{-| A zipper that allows us to zoom in on a particular point in the checkpoint. -}
type CheckpointCursor = Seq CheckpointDifferential

{-| The derivative of 'Checkpoint', used to implement the zipper type 'CheckpointCursor'. -}
data CheckpointDifferential =
    CachePointD ByteString
  | ChoicePointD BranchChoice Checkpoint
  deriving (Eq,Read,Show)

{-| Like 'CheckpointCursor', but each step keeps track of the subtree for the
    alternative branch in case we backtrack to it.
 -}
type Context m α = [ContextStep m α]

{-| Like 'CheckpointDifferential', but left branches include the subtree for the
    right branch; the right branches do not need this information because we
    always explore the left branch first.
 -}
data ContextStep m α =
    CacheContextStep ByteString
  | LeftBranchContextStep Checkpoint (TreeT m α)
  | RightBranchContextStep

instance Show (ContextStep m α) where
    show (CacheContextStep c) = "CacheContextStep[" ++ show c ++ "]"
    show (LeftBranchContextStep checkpoint _) = "LeftBranchContextStep(" ++ show checkpoint ++ ")"
    show RightBranchContextStep = "RightRightBranchContextStep"

------------------------------ Exploration state -------------------------------

{- $state
These types contain information about the state of an exploration in progress.
 -}

{-| The current state of the exploration of a tree starting from a checkpoint. -}
data ExplorationTState m α = ExplorationTState
    {   explorationStateContext :: !(Context m α)
    ,   explorationStateCheckpoint :: !Checkpoint
    ,   explorationStateTree :: !(TreeT m α)
    }

{-| An alias for 'ExplorationTState' in a pure setting. -}
type ExplorationState = ExplorationTState Identity

{-| Constructs the initial 'ExplorationTState' for the given tree. -}
initialExplorationState :: Checkpoint → TreeT m α → ExplorationTState m α
initialExplorationState = ExplorationTState mempty

--------------------------------------------------------------------------------
----------------------------- Utility functions --------------------------------
--------------------------------------------------------------------------------

---------------------------- Checkpoint construction ---------------------------

{-| Constructs a full checkpoint given a (context) checkpoint zipper with a hole
    at your current location and the subcheckpoint at your location.
 -}
checkpointFromContext :: Context m α → Checkpoint → Checkpoint
checkpointFromContext = checkpointFromReversedList $
    \step → case step of
        CacheContextStep value → CachePoint value
        LeftBranchContextStep right_checkpoint _ → flip ChoicePoint right_checkpoint
        RightBranchContextStep → ChoicePoint Explored

{-| Constructs a full checkpoint given a (cursor) checkpoint zipper with a hole
    at your current location and the subcheckpoint at your location.
 -}
checkpointFromCursor :: CheckpointCursor → Checkpoint → Checkpoint
checkpointFromCursor = checkpointFromSequence $
    \step → case step of
        CachePointD value → CachePoint value
        ChoicePointD LeftBranch right_checkpoint → flip ChoicePoint right_checkpoint
        ChoicePointD RightBranch left_checkpoint → ChoicePoint left_checkpoint

{-| Computes the current checkpoint given the state of an exploration. -}
checkpointFromExplorationState :: ExplorationTState m α → Checkpoint
checkpointFromExplorationState ExplorationTState{..} =
    checkpointFromContext explorationStateContext explorationStateCheckpoint

{-| Incrementally builds up a full checkpoint given a sequence corresponding to
    some cursor at a particular location of the full checkpoint and the
    subcheckpoint to splice in at that location.

    The main reason that you should use this function is that, as it builds up
    the full checkpoint, it makes some important simplifications via.
    'simplifyCheckpointRoot', such as replacing @ChoicePoint Explored Explored@
    with @Explored@, which both shrinks the size of the checkpoint as well as
    making it /much/ easier to determine if it is equivalent to 'Explored'. 
 -}
checkpointFromReversedList ::
    (α → (Checkpoint → Checkpoint)) →
    [α] →
    Checkpoint →
    Checkpoint
checkpointFromReversedList processStep = \case
    [] → id
    (step:rest) →
      checkpointFromReversedList processStep rest
      .
      simplifyCheckpointRoot
      .
      processStep step

{-| The same as 'checkpointFromReversedList', but where the cursor is specified
    as a (non-reversed) 'Seq' rather than a list.
 -}
checkpointFromSequence ::
    (α → (Checkpoint → Checkpoint)) →
    Seq α →
    Checkpoint →
    Checkpoint
checkpointFromSequence processStep checkpoint = case viewr checkpoint of
    EmptyR → id
    rest :> step →
        checkpointFromSequence processStep rest
        .
        simplifyCheckpointRoot
        .
        processStep step

{-| Constructs a full checkpoint given the path to where you are currently
    searching and the subcheckpoint at your location, assuming that we have no
    knowledge of anything outside our location (which is indicated by marking it
    as 'Unexplored').
 -}
checkpointFromInitialPath :: Path → Checkpoint → Checkpoint
checkpointFromInitialPath = checkpointFromSequence $
    \step → case step of
        CacheStep c → CachePoint c
        ChoiceStep LeftBranch → flip ChoicePoint Unexplored
        ChoiceStep RightBranch → ChoicePoint Unexplored

{-| Constructs a full checkpoint given the path to where you are currently
    located, assuming that the current location is 'Unexplored' and everything
    outside of our location has been fully explored already.
 -}
checkpointFromUnexploredPath :: Path → Checkpoint
checkpointFromUnexploredPath path = checkpointFromSequence
    (\step → case step of
        CacheStep c → CachePoint c
        ChoiceStep LeftBranch → flip ChoicePoint Explored
        ChoiceStep RightBranch → ChoicePoint Explored
    )
    path
    Unexplored

{-| Applies 'simplifyCheckpointRoot' everywhere in the checkpoint starting from
    the bottom up.
 -}
simplifyCheckpoint :: Checkpoint → Checkpoint
simplifyCheckpoint (ChoicePoint left right) = simplifyCheckpointRoot (ChoicePoint (simplifyCheckpoint left) (simplifyCheckpoint right))
simplifyCheckpoint (CachePoint value checkpoint) = simplifyCheckpointRoot (CachePoint value (simplifyCheckpoint checkpoint))
simplifyCheckpoint checkpoint = checkpoint

------------------------------- Path construction ------------------------------

{-| Computes the path to the current location in the checkpoint as given by the
    context.  (Note that this is a lossy conversation because the resulting path
    does not contain any information about the branches not taken.)
 -}
pathFromContext :: Context m α → Path
pathFromContext = Seq.fromList . map pathStepFromContextStep . reverse

{-| Computes the path to the current location in the checkpoint as given by the
    cursor.  (Note that this is a lossy conversation because the resulting path
    does not contain any information about the branches not taken.)
 -}
pathFromCursor :: CheckpointCursor → Path
pathFromCursor = fmap pathStepFromCursorDifferential

{-| Converts a context step to a path step by throwing away information about
    the alternative branch (if present).
 -}
pathStepFromContextStep :: ContextStep m α → Step
pathStepFromContextStep (CacheContextStep value) = CacheStep value
pathStepFromContextStep (LeftBranchContextStep _ _) = ChoiceStep LeftBranch
pathStepFromContextStep (RightBranchContextStep) = ChoiceStep RightBranch

{-| Converts a cursor differential to a path step by throwing away information
    about the alternative branch (if present).
 -}
pathStepFromCursorDifferential :: CheckpointDifferential → Step
pathStepFromCursorDifferential (CachePointD value) = CacheStep value
pathStepFromCursorDifferential (ChoicePointD active_branch _) = ChoiceStep active_branch

-------------------------------- Miscellaneous ---------------------------------

{-| Inverts a checkpoint so that unexplored areas become explored areas and vice
    versa.  This function satisfies the law that if you sum the result of
    exploring the tree with the original checkpoint and the result of summing
    the tree with the inverted checkpoint then (assuming the result monoid
    commutes) you will get the same result as exploring the entire tree.  That
    is to say,

@
exploreTreeStartingFromCheckpoint checkpoint tree
\<\>
exploreTreeStartingFromCheckpoint (invertCheckpoint checkpoint) tree
==
exploreTree tree
@
 -}
invertCheckpoint :: Checkpoint → Checkpoint
invertCheckpoint Explored = Unexplored
invertCheckpoint Unexplored = Explored
invertCheckpoint (CachePoint value rest) =
    simplifyCheckpointRoot $ CachePoint value (invertCheckpoint rest)
invertCheckpoint (ChoicePoint left right) =
    simplifyCheckpointRoot $ ChoicePoint (invertCheckpoint left) (invertCheckpoint right)

--------------------------------------------------------------------------------
----------------------------- Stepper functions --------------------------------
--------------------------------------------------------------------------------

{- $stepper
The two functions in the in this section are some of the most important
functions in the LogicGrowsOnTrees package, as they provide a means of
incrementally exploring a tree starting from a given checkpoint. The
functionality provided is sufficiently generic that is used by all the various
modes of exploring the tree.
-}

{-| Given the current state of exploration, perform an additional step of
    exploration, returning any solution that was found and the next state of the
    exploration --- which will be 'Nothing' if the entire tree has been
    explored.
 -}
stepThroughTreeStartingFromCheckpoint ::
    ExplorationState α →
    (Maybe α,Maybe (ExplorationState α))
stepThroughTreeStartingFromCheckpoint = runIdentity . stepThroughTreeTStartingFromCheckpoint

{-| Like 'stepThroughTreeStartingFromCheckpoint', but for an impure tree. -}
stepThroughTreeTStartingFromCheckpoint ::
    Monad m ⇒
    ExplorationTState m α →
    m (Maybe α,Maybe (ExplorationTState m α))
stepThroughTreeTStartingFromCheckpoint (ExplorationTState context checkpoint tree) = case checkpoint of
    Explored → return (Nothing, moveUpContext)
    Unexplored → getView >>= \view → case view of
        Return x → return (Just x, moveUpContext)
        Null :>>= _ → return (Nothing, moveUpContext)
        ProcessPendingRequests :>>= k → return (Nothing, Just $ ExplorationTState context checkpoint (TreeT . k $ ()))
        Cache mx :>>= k →
            mx >>= return . maybe
                (Nothing, moveUpContext)
                (\x → (Nothing, Just $
                    ExplorationTState
                        (CacheContextStep (encode x):context)
                        Unexplored
                        (TreeT . k $ x)
                ))
        Choice left right :>>= k → return
            (Nothing, Just $
                ExplorationTState
                    (LeftBranchContextStep Unexplored (right >>= TreeT . k):context)
                    Unexplored
                    (left >>= TreeT . k)
            )
    CachePoint value rest_checkpoint → getView >>= \view → case view of
        ProcessPendingRequests :>>= k → return (Nothing, Just $ ExplorationTState context checkpoint (TreeT . k $ ()))
        Cache _ :>>= k → return
            (Nothing, Just $
                ExplorationTState
                    (CacheContextStep value:context)
                    rest_checkpoint
                    (either error (TreeT . k) . decode $ value)
            )
        _ → throw PastTreeIsInconsistentWithPresentTree
    ChoicePoint left_checkpoint right_checkpoint →  getView >>= \view → case view of
        ProcessPendingRequests :>>= k → return (Nothing, Just $ ExplorationTState context checkpoint (TreeT . k $ ()))
        Choice left right :>>= k → return
            (Nothing, Just $
                ExplorationTState
                    (LeftBranchContextStep right_checkpoint (right >>= TreeT . k):context)
                    left_checkpoint
                    (left >>= TreeT . k)
            )
        _ → throw PastTreeIsInconsistentWithPresentTree
  where
    getView = viewT . unwrapTreeT $ tree
    moveUpContext = go context
      where
        go [] = Nothing
        go (LeftBranchContextStep right_checkpoint right_tree:rest_context) =
            Just (ExplorationTState
                    (RightBranchContextStep:rest_context)
                    right_checkpoint
                    right_tree
                 )
        go (_:rest_context) = go rest_context
{-# INLINE stepThroughTreeTStartingFromCheckpoint #-}

--------------------------------------------------------------------------------
----------------------------- Exploration functions --------------------------------
--------------------------------------------------------------------------------

{- $exploration
The functions in this section explore the remainder of a tree, starting from the
given checkpoint.
-}

{-| Explores the remaining nodes in a pure tree, starting from the
    given checkpoint, and sums over all the results in the leaves.
 -}
exploreTreeStartingFromCheckpoint ::
    Monoid α ⇒
    Checkpoint →
    Tree α →
    α
exploreTreeStartingFromCheckpoint checkpoint tree =
  exploreTreeTStartingFromCheckpoint checkpoint tree |> runIdentity
{-# INLINE exploreTreeStartingFromCheckpoint #-}

{-| Explores the remaining nodes in an impure tree, starting from the
    given checkpoint, and sums over all the results in the leaves.
 -}
exploreTreeTStartingFromCheckpoint ::
    (Monad m, Monoid α) ⇒
    Checkpoint →
    TreeT m α →
    m α
exploreTreeTStartingFromCheckpoint checkpoint tree =
    initialExplorationState checkpoint tree |> go mempty
  where
    go !accum =
        stepThroughTreeTStartingFromCheckpoint
        >=>
        \(maybe_solution,maybe_new_exploration_state) →
            let new_accum = maybe id (flip mappend) maybe_solution accum
            in maybe (return new_accum) (go new_accum) maybe_new_exploration_state
{-# INLINE exploreTreeTStartingFromCheckpoint #-}

{-| Explores all the remaining nodes in a pure tree, starting from the
    given checkpoint, until a result (i.e., a leaf) has been found; if a result
    has been found then it is returned wrapped in 'Just', otherwise 'Nothing' is
    returned.
 -}
exploreTreeUntilFirstStartingFromCheckpoint ::
    Checkpoint →
    Tree α →
    Maybe α
exploreTreeUntilFirstStartingFromCheckpoint checkpoint tree =
  exploreTreeTUntilFirstStartingFromCheckpoint checkpoint tree |> runIdentity

{-| Same as 'exploreTreeUntilFirstStartingFromCheckpoint', but for an impure tree. -}
exploreTreeTUntilFirstStartingFromCheckpoint ::
    Monad m ⇒
    Checkpoint →
    TreeT m α →
    m (Maybe α)
exploreTreeTUntilFirstStartingFromCheckpoint checkpoint tree =
    initialExplorationState checkpoint tree |> go
  where
    go = stepThroughTreeTStartingFromCheckpoint
         >=>
         \(maybe_solution,maybe_new_exploration_state) →
            case maybe_solution of
                Just _ → return maybe_solution
                Nothing → maybe (return Nothing) go maybe_new_exploration_state
{-# INLINE exploreTreeTUntilFirstStartingFromCheckpoint #-}

{-| Explores all the remaining nodes in a tree, starting from the given checkpoint
    and summing all results encountered (i.e., in the leaves) until the current
    partial sum satisfies the condition provided by the first parameter.

    See 'LogicGrowsOnTrees.exploreTreeUntilFound' for more details.
 -}
exploreTreeUntilFoundStartingFromCheckpoint ::
    Monoid α ⇒
    (α → Bool) →
    Checkpoint →
    Tree α →
    (α,Bool)
exploreTreeUntilFoundStartingFromCheckpoint finished checkpoint tree =
  exploreTreeTUntilFoundStartingFromCheckpoint finished checkpoint tree |> runIdentity

{-| Same as 'exploreTreeUntilFoundStartingFromCheckpoint', but for an impure tree. -}
exploreTreeTUntilFoundStartingFromCheckpoint ::
    (Monad m, Monoid α) ⇒
    (α → Bool) →
    Checkpoint →
    TreeT m α →
    m (α,Bool)
exploreTreeTUntilFoundStartingFromCheckpoint finished checkpoint tree =
    initialExplorationState checkpoint tree |> go mempty
  where
    go accum =
        stepThroughTreeTStartingFromCheckpoint
        >=>
        \(maybe_solution,maybe_new_exploration_state) →
            case maybe_solution of
                Nothing → maybe (return (accum,False)) (go accum) maybe_new_exploration_state
                Just solution →
                    let new_accum = accum <> solution
                    in if finished new_accum
                        then return (new_accum,True)
                        else maybe (return (new_accum,False)) (go new_accum) maybe_new_exploration_state
{-# INLINE exploreTreeTUntilFoundStartingFromCheckpoint #-}

