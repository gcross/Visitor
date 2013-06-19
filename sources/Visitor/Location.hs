{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}

{-| This module contains infrastructure for working with 'Location's, which
    indicate a location within a tree but, unlike 'Path', without the cached
    values.
 -}
module Visitor.Location
    (
    -- * Type-classes
      MonadLocatable(..)
    -- * Types
    , Location(..)
    , Solution(..)
    , LocatableT(..)
    , LocatableTreeGenerator(..)
    , LocatableTreeGeneratorIO(..)
    , LocatableTreeGeneratorT(..)
    -- * Utility functions
    , applyCheckpointCursorToLocation
    , applyContextToLocation
    , applyPathToLocation
    , branchingFromLocation
    , labelFromBranching
    , labelFromContext
    , labelFromPath
    , leftBranchOf
    , locationTransformerForBranchChoice
    , normalizeLocatableTreeGenerator
    , normalizeLocatableTreeGeneratorT
    , rightBranchOf
    , rootLocation
    , runLocatableT
    , sendTreeGeneratorDownLocation
    , sendTreeGeneratorTDownLocation
    , solutionsToMap
    -- * Visitor functions
    , visitLocatableTree
    , visitLocatableTreeT
    , visitLocatableTreeTAndIgnoreResults
    , visitTreeWithLocations
    , visitTreeTWithLocations
    , visitTreeWithLocationsStartingAt
    , visitTreeTWithLocationsStartingAt
    , visitLocatableTreeUntilFirst
    , visitLocatableTreeUntilFirstT
    , visitTreeUntilFirstWithLocation
    , visitTreeTUntilFirstWithLocation
    , visitTreeUntilFirstWithLocationStartingAt
    , visitTreeTUntilFirstWithLocationStartingAt
    ) where


import Control.Applicative (Alternative(..),Applicative(..))
import Control.Exception (throw)
import Control.Monad (MonadPlus(..),(>=>),liftM,liftM2)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Operational (ProgramViewT(..),viewT)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.Reader (ReaderT(..),ask)

import Data.Composition
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe (fromJust)
import Data.Monoid
import Data.Foldable as Fold
import Data.Function (on)
import Data.Functor.Identity (Identity,runIdentity)
import Data.Sequence (viewl,ViewL(..))
import Data.SequentialIndex (SequentialIndex,root,leftChild,rightChild)

import Visitor
import Visitor.Checkpoint
import Visitor.Path

--------------------------------------------------------------------------------
--------------------------------- Type-classes ---------------------------------
--------------------------------------------------------------------------------

{-| The class 'MonadLocatable' allows you to get your current location. -}
class MonadPlus m ⇒ MonadLocatable m where
    getLocation :: m Location

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

{-| A 'Location' identifies a location in a tree;  unlike 'Path' it only
    contains information about the list of branches that have been taken, and
    not information about the cached values encounted along the way.
 -}
newtype Location = Location { unwrapLocation :: SequentialIndex } deriving (Eq)

{-| A 'Solution' is a result tagged with the location of the leaf at which it
    was found.
 -}
data Solution α = Solution
    {   solutionLocation :: Location
    ,   solutionResult :: α
    } deriving (Eq,Ord,Show)

{-| The 'Monoid instance constructs a location that is the result of appending
    the path in the second argument to the path in the first argument.
 -}
instance Monoid Location where
    mempty = rootLocation
    xl@(Location x) `mappend` yl@(Location y)
      | x == root = yl
      | y == root = xl
      | otherwise = Location $ go y root x
      where
        go original_label current_label product_label =
            case current_label `compare` original_label of
                EQ → product_label
            -- Note:  the following is counter-intuitive, but it makes sense if you think of it as
            --        being where you need to go to get to the original label instead of where you
            --        currently are with respect to the original label
                GT → (go original_label `on` (fromJust . leftChild)) current_label product_label
                LT → (go original_label `on` (fromJust . rightChild)) current_label product_label

{-| The 'Ord' instance performs the comparison using the list of branches in the
    path defined by the location, which is obtained using the function
    'branchingFromLocation'.
 -}
instance Ord Location where
    compare = compare `on` branchingFromLocation

instance Show Location where
    show = fmap (\branch → case branch of {LeftBranch → 'L'; RightBranch → 'R'}) . branchingFromLocation

{-| 'LocatableT' is a monad transformer that allows you to take any MonadPlus
    and add to it the ability to tell where you are in the tree created by the
    'mplus's.
 -}
newtype LocatableT m α = LocatableT { unwrapLocatableT :: ReaderT Location m α }
    deriving (Applicative,Functor,Monad,MonadIO,MonadTrans)

instance (Alternative m, Monad m) ⇒ Alternative (LocatableT m) where
    empty = LocatableT $ lift empty
    LocatableT left <|> LocatableT right = LocatableT . ReaderT $
        \branch → (runReaderT left (leftBranchOf branch)) <|> (runReaderT right (rightBranchOf branch))

instance MonadPlus m ⇒ MonadLocatable (LocatableT m) where
    getLocation = LocatableT $ ask

instance MonadPlus m ⇒ MonadPlus (LocatableT m) where
    mzero = LocatableT $ lift mzero
    LocatableT left `mplus` LocatableT right = LocatableT . ReaderT $
        \branch → (runReaderT left (leftBranchOf branch)) `mplus` (runReaderT right (rightBranchOf branch))

instance MonadVisitableTrans m ⇒ MonadVisitableTrans (LocatableT m) where
    type NestedMonadInVisitor (LocatableT m) = NestedMonadInVisitor m
    runAndCache = LocatableT . lift . runAndCache
    runAndCacheGuard = LocatableT . lift . runAndCacheGuard
    runAndCacheMaybe = LocatableT . lift . runAndCacheMaybe

instance MonadPlus m ⇒ Monoid (LocatableT m α) where
    mempty = mzero
    mappend = mplus

{-| A 'TreeGenerator' augmented with the ability to get the current location -}
type LocatableTreeGenerator = LocatableTreeGeneratorT Identity

{-| Like 'LocatableTreeGenerator', but running in the IO monad. -}
type LocatableTreeGeneratorIO = LocatableTreeGeneratorT IO

{-| Like 'LocatableTreeGenerator', but running in an arbitrary monad. -}
newtype LocatableTreeGeneratorT m α = LocatableTreeGeneratorT { unwrapLocatableTreeGeneratorT :: LocatableT (TreeGeneratorT m) α }
    deriving (Alternative,Applicative,Functor,Monad,MonadIO,MonadLocatable,MonadPlus,Monoid)

instance MonadTrans LocatableTreeGeneratorT where
    lift = LocatableTreeGeneratorT . lift . lift

instance Monad m ⇒ MonadVisitableTrans (LocatableTreeGeneratorT m) where
    type NestedMonadInVisitor (LocatableTreeGeneratorT m) = m
    runAndCache = LocatableTreeGeneratorT . runAndCache
    runAndCacheGuard = LocatableTreeGeneratorT . runAndCacheGuard
    runAndCacheMaybe = LocatableTreeGeneratorT . runAndCacheMaybe

--------------------------------------------------------------------------------
---------------------------------- Functions -----------------------------------
--------------------------------------------------------------------------------

------------------------------ Utility functions -------------------------------

{-| Append the path indicated by a checkpoint cursor to a location's path. -}
applyCheckpointCursorToLocation ::
    CheckpointCursor {-^ a path within the subtree -} →
    Location {-^ the location of the subtree -} →
    Location {-^ the location within the subtree obtained by following the path
                 indicated by the checkpoint cursor
              -}
applyCheckpointCursorToLocation cursor =
    case viewl cursor of
        EmptyL → id
        step :< rest →
            applyCheckpointCursorToLocation rest
            .
            case step of
                CachePointD _ → id
                ChoicePointD active_branch _ → locationTransformerForBranchChoice active_branch

{-| Append the path indicated by a context to a location's path. -}
applyContextToLocation ::
    Context m α {-^ the path within the subtree -} →
    Location {-^ the location of the subtree -} →
    Location {-^ the location within the subtree obtained by following the path
                 indicated by the context
              -}
applyContextToLocation context =
    case viewl context of
        EmptyL → id
        step :< rest →
            applyContextToLocation rest
            .
            case step of
                CacheContextStep _ → id
                LeftBranchContextStep _ _ → leftBranchOf
                RightBranchContextStep → rightBranchOf

{-| Append a path to a location's path. -}
applyPathToLocation ::
    Path {-^ a path within the subtree -} →
    Location {-^ the location of the subtree -} →
    Location {-^ the location within the subtree obtained by following the given path -}
applyPathToLocation path =
    case viewl path of
        EmptyL → id
        step :< rest →
            applyPathToLocation rest
            .
            case step of
                ChoiceStep active_branch → locationTransformerForBranchChoice active_branch
                CacheStep _ → id

{-| Converts a location to a list of branch choices. -}
branchingFromLocation :: Location → [BranchChoice]
branchingFromLocation = go root . unwrapLocation
  where
    go current_label original_label =
        case current_label `compare` original_label of
            EQ → []
            GT → LeftBranch:go (fromJust . leftChild $ current_label) original_label
            LT → RightBranch:go (fromJust . rightChild $ current_label) original_label

{-| Converts a list (or other 'Foldable') of branch choices to a location. -}
labelFromBranching :: Foldable t ⇒ t BranchChoice → Location
labelFromBranching = Fold.foldl' (flip locationTransformerForBranchChoice) rootLocation

{-| Contructs a 'Location' representing the location within the tree indicated by the 'Context'. -}
labelFromContext :: Context m α → Location
labelFromContext = flip applyContextToLocation rootLocation

{-| Contructs a 'Location' representing the location within the tree indicated by the 'Path'. -}
labelFromPath :: Path → Location
labelFromPath = flip applyPathToLocation rootLocation

{-| Returns the 'Location' at the left branch of the given location. -}
leftBranchOf :: Location → Location
leftBranchOf = Location . fromJust . leftChild . unwrapLocation

{-| Convenience function takes a branch choice and returns a location
    transformer that appends the branch choice to the given location.
 -}
locationTransformerForBranchChoice :: BranchChoice → (Location → Location)
locationTransformerForBranchChoice LeftBranch = leftBranchOf
locationTransformerForBranchChoice RightBranch = rightBranchOf

{-| Converts a 'LocatableTreeGenerator' to a 'TreeGenerator'. -}
normalizeLocatableTreeGenerator :: LocatableTreeGenerator α → TreeGenerator α
normalizeLocatableTreeGenerator = runLocatableT . unwrapLocatableTreeGeneratorT

{-| Converts a 'LocatableTreeGeneratorT' to a 'TreeGeneratorT'. -}
normalizeLocatableTreeGeneratorT :: LocatableTreeGeneratorT m α → TreeGeneratorT m α
normalizeLocatableTreeGeneratorT = runLocatableT . unwrapLocatableTreeGeneratorT

{-| Returns the 'Location' at the right branch of the given location. -}
rightBranchOf :: Location → Location
rightBranchOf = Location . fromJust . rightChild . unwrapLocation

{-| The location at the root of the tree. -}
rootLocation :: Location
rootLocation = Location root

{-| Runs a 'LocatableT' to obtain the nested monad. -}
runLocatableT :: LocatableT m α → m α
runLocatableT = flip runReaderT rootLocation . unwrapLocatableT

{-| Guides a 'TreeGenerator' guiding it to the subtree at the given 'Location'.
    This function is analagous to 'Visitor.Path.sendTreeGeneratorDownPath', and
    shares the same caveats.
 -}
sendTreeGeneratorDownLocation :: Location → TreeGenerator α → TreeGenerator α
sendTreeGeneratorDownLocation label = runIdentity . sendTreeGeneratorTDownLocation label

{-| Like 'sendTreeGeneratorDownLocation', but for impure tree generators. -}
sendTreeGeneratorTDownLocation :: Monad m ⇒ Location → TreeGeneratorT m α → m (TreeGeneratorT m α)
sendTreeGeneratorTDownLocation (Location label) = go root
  where
    go parent visitor
      | parent == label = return visitor
      | otherwise =
          (viewT . unwrapTreeGeneratorT) visitor >>= \view → case view of
            Return _ → throw VisitorTerminatedBeforeEndOfWalk
            Null :>>= _ → throw VisitorTerminatedBeforeEndOfWalk
            Cache mx :>>= k → mx >>= maybe (throw VisitorTerminatedBeforeEndOfWalk) (go parent . TreeGeneratorT . k)
            Choice left right :>>= k →
                if parent > label
                then
                    go
                        (fromJust . leftChild $ parent)
                        (left >>= TreeGeneratorT . k)
                else
                    go
                        (fromJust . rightChild $ parent)
                        (right >>= TreeGeneratorT . k)

{-| Converts a list (or other 'Foldable') of solutions to a 'Map' from
    'Location's to results.
 -}
solutionsToMap :: Foldable t ⇒ t (Solution α) → Map Location α
solutionsToMap = Fold.foldl' (flip $ \(Solution label solution) → Map.insert label solution) Map.empty

------------------------------ Visitor functions -------------------------------

{-| Visit all the nodes in a tree generated by a LocatableTreeGenerator and sum
    over all the results in the leaves.
 -}
visitLocatableTree :: Monoid α ⇒ LocatableTreeGenerator α → α
visitLocatableTree = visitTree . runLocatableT . unwrapLocatableTreeGeneratorT

{-| Same as 'visitLocatableTree', but for an impurely generated tree. -}
visitLocatableTreeT :: (Monoid α,Monad m) ⇒ LocatableTreeGeneratorT m α → m α
visitLocatableTreeT = visitTreeT . runLocatableT . unwrapLocatableTreeGeneratorT

{-| Same as 'visitLocatableTree', but the results are discarded so the tree is
    only visited for the side-effects of the generator.
 -}
visitLocatableTreeTAndIgnoreResults :: Monad m ⇒ LocatableTreeGeneratorT m α → m ()
visitLocatableTreeTAndIgnoreResults = visitTreeTAndIgnoreResults . runLocatableT . unwrapLocatableTreeGeneratorT

{-| Visits all of the nodes of a tree, returning a list of solutions each
    tagged with the location at which it was found.
 -}
visitTreeWithLocations :: TreeGenerator α → [Solution α]
visitTreeWithLocations = runIdentity . visitTreeTWithLocations

{-| Like 'visitTreeWithLocations' but for an impurely generated tree. -}
visitTreeTWithLocations :: Monad m ⇒ TreeGeneratorT m α → m [Solution α]
visitTreeTWithLocations = visitTreeTWithLocationsStartingAt rootLocation

{-| Like 'visitTreeWithLocations', but for a subtree whose location is given by
    the first argument;  the solutions are labeled by the /absolute/ location
    within the full tree (as opposed to their relative location within the
    subtree).
 -}
visitTreeWithLocationsStartingAt :: Location → TreeGenerator α → [Solution α]
visitTreeWithLocationsStartingAt = runIdentity .* visitTreeTWithLocationsStartingAt

{-| Like 'visitTreeWithLocationsStartingAt' but for an impurely generated trees. -}
visitTreeTWithLocationsStartingAt :: Monad m ⇒ Location → TreeGeneratorT m α → m [Solution α]
visitTreeTWithLocationsStartingAt label =
    viewT . unwrapTreeGeneratorT >=> \view →
    case view of
        Return x → return [Solution label x]
        (Cache mx :>>= k) → mx >>= maybe (return []) (visitTreeTWithLocationsStartingAt label . TreeGeneratorT . k)
        (Choice left right :>>= k) →
            liftM2 (++)
                (visitTreeTWithLocationsStartingAt (leftBranchOf label) $ left >>= TreeGeneratorT . k)
                (visitTreeTWithLocationsStartingAt (rightBranchOf label) $ right >>= TreeGeneratorT . k)
        (Null :>>= _) → return []

{-| Visits all the nodes in a locatable tree until a result (i.e., a leaf) has
    been found; if a result has been found then it is returned wrapped in
    'Just', otherwise 'Nothing' is returned.
 -}
visitLocatableTreeUntilFirst :: LocatableTreeGenerator α → Maybe α
visitLocatableTreeUntilFirst = visitTreeUntilFirst . runLocatableT . unwrapLocatableTreeGeneratorT

{-| Like 'visitLocatableTreeUntilFirst' but for an impurely generated tree. -}
visitLocatableTreeUntilFirstT :: Monad m ⇒ LocatableTreeGeneratorT m α → m (Maybe α)
visitLocatableTreeUntilFirstT = visitTreeTUntilFirst . runLocatableT . unwrapLocatableTreeGeneratorT

{-| Visits all the nodes in a tree until a result (i.e., a leaf) has been found;
    if a result has been found then it is returned tagged with the location at
    which it was found and wrapped in 'Just', otherwise'Nothing' is returned.
 -}
visitTreeUntilFirstWithLocation :: TreeGenerator α → Maybe (Solution α)
visitTreeUntilFirstWithLocation = runIdentity . visitTreeTUntilFirstWithLocation

{-| Like 'visitTreeUntilFirstWithLocation' but for an impurely generated tree. -}
visitTreeTUntilFirstWithLocation :: Monad m ⇒ TreeGeneratorT m α → m (Maybe (Solution α))
visitTreeTUntilFirstWithLocation = visitTreeTUntilFirstWithLocationStartingAt rootLocation

{-| Like 'visitTreeUntilFirstWithLocation', but for a subtree whose location is
    given by the first argument; the solution (if present) is labeled by the
    /absolute/ location within the full tree (as opposed to its relative
    location within the subtree).
 -}
visitTreeUntilFirstWithLocationStartingAt :: Location → TreeGenerator α → Maybe (Solution α)
visitTreeUntilFirstWithLocationStartingAt = runIdentity .* visitTreeTUntilFirstWithLocationStartingAt

{-| Like 'visitTreeUntilFirstWithLocationStartingAt' but for an impurely generated tree. -}
visitTreeTUntilFirstWithLocationStartingAt :: Monad m ⇒ Location → TreeGeneratorT m α → m (Maybe (Solution α))
visitTreeTUntilFirstWithLocationStartingAt = go .* visitTreeTWithLocationsStartingAt
  where
    go = liftM $ \solutions →
        case solutions of
            [] → Nothing
            (x:_) → Just x
