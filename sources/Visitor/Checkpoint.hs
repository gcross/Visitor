{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}

{-| This module contains the infrastructure used to maintain a checkpoint during
    a tree exploration so that if the exploration is interrupted one can start
    immediately from where one had been rather than having to start over from
    scratch.
 -}
module Visitor.Checkpoint
    (
    -- * Types
      Checkpoint(..)
    , Progress(..)
    -- ** Cursors and contexts
    -- $cursors
    , CheckpointCursor(..)
    , CheckpointDifferential(..)
    , Context(..)
    , ContextStep(..)
    -- ** Exploration state
    , VisitorTState(..)
    , VisitorState(..)
    , initialVisitorState
    -- * Exceptions
    , InconsistentCheckpoints(..)
    -- * Utility functions
    -- ** Checkpoint construction
    , checkpointFromContext
    , checkpointFromCursor
    , checkpointFromVisitorState
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
    -- * Visitor functions
    -- $visitor
    , visitTreeStartingFromCheckpoint
    , visitTreeTStartingFromCheckpoint
    , visitTreeUntilFirstStartingFromCheckpoint
    , visitTreeTUntilFirstStartingFromCheckpoint
    , visitTreeUntilFoundStartingFromCheckpoint
    , visitTreeTUntilFoundStartingFromCheckpoint
    ) where

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

--------------------------------------------------------------------------------
--------------------------------- Exceptions -----------------------------------
--------------------------------------------------------------------------------

{-| This exception is thrown when one attempts to merge checkpoints that
    disagree with each other; this will never happen as long as you only merge
    checkpoints that came from the same tree generator, so if you get this
    exception then there is almost certainly a bug in your code.
 -}
data InconsistentCheckpoints = InconsistentCheckpoints Checkpoint Checkpoint deriving (Eq,Show,Typeable)

instance Exception InconsistentCheckpoints

--------------------------------------------------------------------------------
----------------------------------- Types --------------------------------------
--------------------------------------------------------------------------------

{-| This type contains information about the parts of a tree that have been
    explored.
 -}
data Checkpoint =
    CachePoint ByteString Checkpoint
  | ChoicePoint Checkpoint Checkpoint
  | Explored
  | Unexplored
  deriving (Eq,Ord,Read,Show)
$( derive makeSerialize ''Checkpoint )

-- Note:  This function is not in the same place where it appears in the documentation.
{-| This function simplifies the root of the checkpoint by replacing

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
    explorations of a given tree generator and merge them together to obtain a
    checkpoint that indicates *all* of the areas that have been explored by
    anyone so far. For example, if the two checkpoints are @ChoicePoint Explored
    Unexplored@ and @ChoicePoint Unexplored (ChoicePoint Explored Unexplored)@
    then the result will be @ChoicePoint Explored (ChoicePoint Explored
    Unexplored)@.

    WARNING: This 'Monoid' instance is a /partial/ function that expects
    checkpoints that have come from the /same/ tree generator; if this
    precondition is not met then if you are lucky it will notice the
    inconsistency and throw an exception to let you know that something is wrong
    and if you are not then it will silently give you a nonsense result. You are
    /very/ unlikely to run into this problem unless for some reason you are
    juggling multiple tree generators and have mixed up which checkpoint goes
    with which generator, which is something that is neither done nor encouraged
    in this package.
 -}
instance Monoid Checkpoint where
    mempty = Unexplored
    Explored `mappend` _ = Explored
    _ `mappend` Explored = Explored
    Unexplored `mappend` x = x
    x `mappend` Unexplored = x
    (ChoicePoint lx rx) `mappend` (ChoicePoint ly ry) =
        simplifyCheckpointRoot (ChoicePoint (lx `mappend` ly) (rx `mappend` ry))
    (CachePoint cx x) `mappend` (CachePoint cy y)
      | cx == cy = simplifyCheckpointRoot (CachePoint cx (x `mappend` y))
    mappend x y = throw (InconsistentCheckpoints x y)

{-| This type contains information both about current checkpoint and about the
    results we have gathered so far.
 -}
data Progress α = Progress
    {   progressCheckpoint :: Checkpoint
    ,   progressResult :: α
    } deriving (Eq,Show)
$( derive makeMonoid ''Progress )
$( derive makeSerialize ''Progress )

instance Functor Progress where
    fmap f (Progress checkpoint result) = Progress checkpoint (f result)

---------------------------- Cursors and contexts ------------------------------

{- $cursors
The types in this subsection are essentially two kinds of zippers for the
'Checkpoint' type.  Put another way, as we explore a tree they represent where
we are and how how to backtrack and explore other branches in tree.

The difference between the two types that do this is that, at each branch,
'Context' keeps around the generator needed to generate the tree for that branch
whereas 'CheckpointCursor' does not. The reason for there being two different
types is workload stealing; specifically, when a branch has been stolen from us
we want to forget about the generator for it because we are no longer going to
explore that branch ourselves; thus, workload stealing converts 'ContextStep's
to 'CheckpointDifferential's. Put another way, as a worker (implemented in
"Visitor.Worker") explores the tree at all times it has a 'CheckpointCursor'
which tells us about the decisions that it made which are /frozen/ as we will
never backtrack into them to explore the other branch and a 'Context' which
tells us about where we need to backtrack to explore the rest of the workload
assigned to us.
 -}

{-| A zipper that allows us to zoom in on a particular point in the Checkpoint. -}
type CheckpointCursor = Seq CheckpointDifferential

{-| The derivative of 'Checkpoint', used to implement the zipper type 'CheckpointCursor' -}
data CheckpointDifferential =
    CachePointD ByteString
  | ChoicePointD BranchChoice Checkpoint
  deriving (Eq,Read,Show)

{-| Like 'CheckpointCursor', but each step keeps track of the generator for the
    alternative branch in case we backtrack to it.
 -}
type Context m α = Seq (ContextStep m α)

{-| Like 'CheckpointDifferential', but left branches include the generator
    needed to generate the right branch;  the right branches do not need this
    information because we always explore the left branch first.
 -}
data ContextStep m α =
    CacheContextStep ByteString
  | LeftBranchContextStep Checkpoint (TreeGeneratorT m α)
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
data VisitorTState m α = VisitorTState
    {   visitorStateContext :: !(Context m α)
    ,   visitorStateCheckpoint :: !Checkpoint
    ,   visitorStateVisitor :: !(TreeGeneratorT m α)
    }

{-| An alias for 'VisitorTState' in a pure setting. -}
type VisitorState = VisitorTState Identity

{-| Constructs the initial 'VisitorTState' for the given tree generator. -}
initialVisitorState :: Checkpoint → TreeGeneratorT m α → VisitorTState m α
initialVisitorState = VisitorTState Seq.empty

--------------------------------------------------------------------------------
----------------------------- Utility functions --------------------------------
--------------------------------------------------------------------------------

---------------------------- Checkpoint construction ---------------------------

{-| Constructs a full checkpoint given where you are at (as indicated by the
    context) and the subcheckpoint at your location.
 -}
checkpointFromContext ::
  Context m α {-^ indicates where you are at in the full checkpoint -} →
  Checkpoint {-^ indicates the subcheckpoint to splice in at your location -} →
  Checkpoint {-^ the resulting full checkpoint -}
checkpointFromContext = checkpointFromSequence $
    \step → case step of
        CacheContextStep cache → CachePoint cache
        LeftBranchContextStep right_checkpoint _ → flip ChoicePoint right_checkpoint
        RightBranchContextStep → ChoicePoint Explored

{-| Constructs a full checkpoint given where you are at (as indicated by the
    cursor) and the subcheckpoint at your location.
 -}
checkpointFromCursor ::
    CheckpointCursor {-^ indicates where you are at in the full checkpoint -} →
    Checkpoint {-^ indicates the subcheckpoint to splice in at your location -} →
    Checkpoint {-^ the resulting full checkpoint -}
checkpointFromCursor = checkpointFromSequence $
    \step → case step of
        CachePointD cache → CachePoint cache
        ChoicePointD LeftBranch right_checkpoint → flip ChoicePoint right_checkpoint
        ChoicePointD RightBranch left_checkpoint → ChoicePoint left_checkpoint

{-| Computes the current checkpoint given the state of a visitor. -}
checkpointFromVisitorState :: VisitorTState m α → Checkpoint
checkpointFromVisitorState VisitorTState{..} =
    checkpointFromContext visitorStateContext visitorStateCheckpoint

{-| This function incrementally builds up a full checkpoint given a sequence
    corresponding to some cursor at a particular location of the full checkpoint
    and the subcheckpoint to splice in at that location.

    The main reason that you should use this function is that, as it builds up
    the full checkpoint, it makes some important simplifications via.
    'simplifyCheckpointRoot', such as replacing @ChoicePoint Explored Explored@
    with @Explored@, without which the final result would be much larger and
    more complicated than necessary.
 -}
checkpointFromSequence ::
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
            simplifyCheckpointRoot
            .
            processStep step

{-| Constructs a full checkpoint given the path to where you are currently
    searching and the subcheckpoint at your location, assuming that we have no
    knowledge of anything outside our location (which is indicated by marking it
    as "unexplored").
 -}
checkpointFromInitialPath ::
    Path {-^ path to the current location -} →
    Checkpoint {-^ subcheckpoint to splice in at the current location -} →
    Checkpoint {-^ full checkpoint with unknown parts marked as 'Unexplored'. -}
checkpointFromInitialPath = checkpointFromSequence $
    \step → case step of
        CacheStep c → CachePoint c
        ChoiceStep LeftBranch → flip ChoicePoint Unexplored
        ChoiceStep RightBranch → ChoicePoint Unexplored

{-| Constructs a full checkpoint given the path to where you are currently
    searching, assuming that the current location is 'Unexplored' and everything
    outside of our location has been fully explored already.
 -}
checkpointFromUnexploredPath ::
    Path {-^ path to the current location -} →
    Checkpoint {-^ full checkpoint with current location marked as 'Unexplored'
                   and everywhere else marked as 'Explored'.
                -}
checkpointFromUnexploredPath path = checkpointFromSequence
    (\step → case step of
        CacheStep c → CachePoint c
        ChoiceStep LeftBranch → flip ChoicePoint Explored
        ChoiceStep RightBranch → ChoicePoint Explored
    )
    path
    Unexplored

{-| This function applies 'simplifyCheckpointRoot' everywhere in the checkpoint
    starting from the bottom up.
 -}
simplifyCheckpoint :: Checkpoint → Checkpoint
simplifyCheckpoint (ChoicePoint left right) = simplifyCheckpointRoot (ChoicePoint (simplifyCheckpoint left) (simplifyCheckpoint right))
simplifyCheckpoint (CachePoint cache checkpoint) = simplifyCheckpointRoot (CachePoint cache (simplifyCheckpoint checkpoint))
simplifyCheckpoint checkpoint = checkpoint

------------------------------- Path construction ------------------------------

{-| Computes the path to the current location in the checkpoint as given by the
    context.  (Note that this is a lossy conversation because the resulting path
    does not contain any information about the branches not taken.)
 -}
pathFromContext :: Context m α → Path
pathFromContext = fmap pathStepFromContextStep

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
pathStepFromContextStep (CacheContextStep cache) = CacheStep cache
pathStepFromContextStep (LeftBranchContextStep _ _) = ChoiceStep LeftBranch
pathStepFromContextStep (RightBranchContextStep) = ChoiceStep RightBranch

{-| Converts a cursor differential to a path step by throwing away information
    about the alternative branch (if present).
 -}
pathStepFromCursorDifferential :: CheckpointDifferential → Step
pathStepFromCursorDifferential (CachePointD cache) = CacheStep cache
pathStepFromCursorDifferential (ChoicePointD active_branch _) = ChoiceStep active_branch

-------------------------------- Miscellaneous ---------------------------------

{-| Inverts a checkpoint so that unexplored areas become explored areas and vice
    versa.  This function satisfies the law that if you sum the result of
    exploring the tree with the original checkpoint and the result of summing
    the tree with the inverted checkpoint then (assuming the result monoid
    commutes) you will get the same result as exploring the entire tree.  That
    is to say,

    @
    visitTreeStartingFromCheckpoint checkpoint generator <>
        visitTreeStartingFromCheckpoint (invertCheckpoint checkpoint) generator
            == visitTree generator
    @
 -}
invertCheckpoint :: Checkpoint → Checkpoint
invertCheckpoint Explored = Unexplored
invertCheckpoint Unexplored = Explored
invertCheckpoint (CachePoint cache rest) =
    simplifyCheckpointRoot (CachePoint cache (invertCheckpoint rest))
invertCheckpoint (ChoicePoint left right) =
    simplifyCheckpointRoot (ChoicePoint (invertCheckpoint left) (invertCheckpoint right))

--------------------------------------------------------------------------------
----------------------------- Stepper functions --------------------------------
--------------------------------------------------------------------------------

{- $stepper
The two functions in the in this section are some of the most important
functions in the Visitor package, as they provide a means of incrementally
exploring a tree starting from a given checkpoint.  The functionality provided
is sufficiently generic that is used by all the various modes of visiting the
tree.
-}

{-| Given the current state of exploration, perform an additional step of
    exploration, return any solution that was found and the next state of the
    exploration -- which will be 'Nothing' if the entire tree has been explored.
 -}
stepThroughTreeStartingFromCheckpoint ::
    VisitorState α →
    (Maybe α,Maybe (VisitorState α))
stepThroughTreeStartingFromCheckpoint = runIdentity . stepThroughTreeTStartingFromCheckpoint

{-| Like 'stepThroughTreeStartingFromCheckpoint', but for an impurely generated tree. -}
stepThroughTreeTStartingFromCheckpoint ::
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
                        (TreeGeneratorT . k $ x)
                ))
        Choice left right :>>= k → return
            (Nothing, Just $
                VisitorTState
                    (context |> LeftBranchContextStep Unexplored (right >>= TreeGeneratorT . k))
                    Unexplored
                    (left >>= TreeGeneratorT . k)
            )
    CachePoint cache rest_checkpoint → getView >>= \view → case view of
        Cache _ :>>= k → return
            (Nothing, Just $
                VisitorTState
                    (context |> CacheContextStep cache)
                    rest_checkpoint
                    (either error (TreeGeneratorT . k) . decode $ cache)
            )
        _ → throw PastVisitorIsInconsistentWithPresentVisitor
    ChoicePoint left_checkpoint right_checkpoint →  getView >>= \view → case view of
        Choice left right :>>= k → return
            (Nothing, Just $
                VisitorTState
                    (context |> LeftBranchContextStep right_checkpoint (right >>= TreeGeneratorT . k))
                    left_checkpoint
                    (left >>= TreeGeneratorT . k)
            )
        _ → throw PastVisitorIsInconsistentWithPresentVisitor
  where
    getView = viewT . unwrapTreeGeneratorT $ visitor
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

--------------------------------------------------------------------------------
----------------------------- Visitor functions --------------------------------
--------------------------------------------------------------------------------

{- $visitor
The functions in this section visit the remainder of a tree, starting from the
given checkpoint.
-}

{-| Visits the remaining nodes in a purely generated tree, starting from the
    given checkpoint, and sums over all the results in the leaves.
 -}
visitTreeStartingFromCheckpoint ::
    Monoid α ⇒
    Checkpoint →
    TreeGenerator α →
    α
visitTreeStartingFromCheckpoint = runIdentity .* visitTreeTStartingFromCheckpoint

{-| Visits the remaining nodes in an impurely generated tree, starting from the
    given checkpoint, and sums over all the results in the leaves.
 -}
visitTreeTStartingFromCheckpoint ::
    (Monad m, Monoid α) ⇒
    Checkpoint →
    TreeGeneratorT m α →
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

{-| Visits all the remaining nodes in a purely generated tree, starting from the
    given checkpoint, until a result (i.e., a leaf) has been found; if a result
    has been found then it is returned wrapped in 'Just', otherwise 'Nothing' is
    returned.
 -}
visitTreeUntilFirstStartingFromCheckpoint ::
    Checkpoint →
    TreeGenerator α →
    Maybe α
visitTreeUntilFirstStartingFromCheckpoint = runIdentity .* visitTreeTUntilFirstStartingFromCheckpoint

{-| Same as 'visitTreeUntilFirstStartingFromCheckpoint', but for an impurely generated tree. -}
visitTreeTUntilFirstStartingFromCheckpoint ::
    Monad m ⇒
    Checkpoint →
    TreeGeneratorT m α →
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

{-| Visits all the remaining nodes in a tree, starting from the given checkpoint
    and summing all results encountered (i.e., in the leaves) until the current
    partial sum satisfies the condition provided by the first function; if this
    condition is ever satisfied then its result is returned in 'Right',
    otherwise the final sum is returned in 'Left'.
 -}
visitTreeUntilFoundStartingFromCheckpoint ::
    Monoid α ⇒
    (α → Maybe β) →
    Checkpoint →
    TreeGenerator α →
    Either α β
visitTreeUntilFoundStartingFromCheckpoint = runIdentity .** visitTreeTUntilFoundStartingFromCheckpoint

{-| Same as 'visitTreeUntilFoundStartingFromCheckpoint', but for an impurely generated tree. -}
visitTreeTUntilFoundStartingFromCheckpoint ::
    (Monad m, Monoid α) ⇒
    (α → Maybe β) →
    Checkpoint →
    TreeGeneratorT m α →
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

