{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UnicodeSyntax #-}

{-| Basic functionality for building and exploring trees. -}
module LogicGrowsOnTrees
    (
    -- * Tree types
    -- $types
      Tree
    , TreeIO
    , TreeT(..)
    -- * Explorable class features
    -- $type-classes
    , MonadExplorable(..)
    , MonadExplorableTrans(..)
    -- * Functions
    -- $functions

    -- ** ...that explore trees
    -- $runners
    , exploreTree
    , exploreTreeT
    , exploreTreeTAndIgnoreResults
    , exploreTreeUntilFirst
    , exploreTreeTUntilFirst
    , exploreTreeUntilFound
    , exploreTreeTUntilFound
    -- ** ...that help building trees
    -- $builders
    , allFrom
    , allFromBalanced
    , allFromBalancedBottomUp
    , between
    , msumBalanced
    , msumBalancedBottomUp
    -- ** ...that transform trees
    , endowTree
    -- * Implementation
    , TreeTInstruction(..)
    , TreeInstruction
    ) where

import Control.Applicative (Alternative(..),Applicative(..))
import Control.Monad (MonadPlus(..),(>=>),guard,liftM,liftM2,msum)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Operational (ProgramT,ProgramViewT(..),singleton,view,viewT)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.List (ListT)
import Control.Monad.Trans.Maybe (MaybeT)

import Data.Foldable (Foldable)
import qualified Data.Foldable as Fold

import Data.Array ((!),listArray)
import Data.Functor.Identity (Identity(..),runIdentity)
import Data.Maybe (isJust)
import Data.Monoid ((<>),Monoid(..))
import Data.Serialize (Serialize(),encode)

import LogicGrowsOnTrees.Utils.MonadPlusForest

--------------------------------------------------------------------------------
------------------------------------- Types ------------------------------------
--------------------------------------------------------------------------------

{- $types
The following are the tree types that are accepted by most of he
functions in this package.  You do not need to know the details of their
definitions unless you intend to write your own custom routines for running and
transforming trees, in which case the relevant information is at the bottom
of this page in the Implementation section.

There is one type of pure tree and two types of impure trees.
In general, your tree should nearly always be pure if you are planning
to make use of checkpointing or parallel exploring, because in general parts of
the tree may be explored multiple times, some parts may not be run at all on a
given processor, and whenever a leaf is hit there will be a jump to a higher
node, so if your tree is impure the effects need to be meaningful no
matter how the tree is run on a given processor.

Having said that, there are a few times when an impure tree can make sense:
first, if the inner monad is something like the `Reader` monad, which has no
side-effects; second, for testing purposes (e.g., many of my tests of the
various tree explorers use `MVar`s and the like to ensure that trees are
explored in a certain way to test certain code paths); finally, if there is some
side-effectful action that you want to run on each result (such as storing a
result into a database), though in this case you will need to make sure that
your code is robust against being run multiple times as there is no guarantee in
an environment where the system might be shut down and resumed from a checkpoint
that your action will only have been run once on a given result (i.e., if the
system goes down after your action was run but before a checkpoint was made
marking that its node was explored).

If you need something like state in your tree, then you should consider
nesting the tree monad in the state monad rather than vice-versa,
because this will do things like automatically erasing the change in state that
happened between an inner node and a leaf when the tree jumps back up
from the leaf to an inner node, which will usually be what you want.
-}

{-| A pure tree, which is what you should normally be using. -}
type Tree = TreeT Identity

{-| A tree running in the I/O monad, which you should only be using for
    testing purposes or, say, if you are planning on storing each result in an
    external database, in which case you need to guard against the possibility
    that an action for a given result might be run twice in checkpointing and/or
    parallel settings.
-}
type TreeIO = TreeT IO

{-| A tree run in an arbitrary monad. -}
newtype TreeT m α = TreeT { unwrapTreeT :: ProgramT (TreeTInstruction m) m α }
    deriving (Applicative,Functor,Monad,MonadIO)

--------------------------------------------------------------------------------
--------------------------------- Type-classes ---------------------------------
--------------------------------------------------------------------------------

{- $type-classes

'Tree's are instances of 'MonadExplorable' and/or 'MonadExplorableTrans',
which are both subclasses of 'MonadPlus'. The additional functionality offered
by these type-classes is the ability to cache results so that a computation does
not need to be repeated when a node is explored a second time, which can happen
either when resuming from a checkpoint or when a workload has been stolen by
another processor as the first step is to retrace the path through the tree
that leads to the stolen workload.

These features could have been provided as functions, but there are two reasons
why they were subsumed into type-classes: first, because one might want to
add another layer above the 'Tree' monad transformers in the monad stack
(as is the case in "LogicGrowsOnTrees.Location"), and second, because one might want
to run a tree using a simpler monad such as [] for testing purposes.

NOTE:  Caching a computation takes space in the 'Checkpoint', so it is something
       you should only do when the result is relatively small and the
       computation is very expensive and is high enough in the search tree that
       it is likely to be repeated often.  If the calculation is low enough in
       the search tree that it is unlikely to be repeated, is cheap enough so
       that repeating it is not a big deal, or produces a result with an
       incredibly large memory footprint, then you are probably better off not
       caching the result.
 -}

{-| The 'MonadExplorable' class provides caching functionality when exploring a
    tree;  at minimum 'cacheMaybe' needs to be defined.
 -}
class MonadPlus m ⇒ MonadExplorable m where
    {-| Cache a value in case we explore this node again. -}
    cache :: Serialize x ⇒ x → m x
    cache = cacheMaybe . Just

    {-| This does the same thing as 'guard' but it caches the result. -}
    cacheGuard :: Bool → m ()
    cacheGuard = cacheMaybe . (\x → if x then Just () else Nothing)

    {-| This function is a combination of the previous two;  it performs a
        computation which might fail by returning 'Nothing', and if that happens
        it aborts the tree;  if it passes then the result is cached and
        returned.

        Note that the previous two methods are essentially specializations of
        this method.
     -}
    cacheMaybe :: Serialize x ⇒ Maybe x → m x

{-| This class is like 'MonadExplorable', but it is designed to work with monad
    stacks;  at minimum 'runAndCacheMaybe' needs to be defined.
 -}
class (MonadPlus m, Monad (NestedMonad m)) ⇒ MonadExplorableTrans m where
    {-| The next layer down in the monad transformer stack. -}
    type NestedMonad m :: * → *

    {-| Runs the given action in the nested monad and caches the result. -}
    runAndCache :: Serialize x ⇒ (NestedMonad m) x → m x
    runAndCache = runAndCacheMaybe . liftM Just

    {-| Runs the given action in the nested monad and then does the equivalent
        of feeding it into 'guard', caching the result.
     -}
    runAndCacheGuard :: (NestedMonad m) Bool → m ()
    runAndCacheGuard = runAndCacheMaybe . liftM (\x → if x then Just () else Nothing)

    {-| Runs the given action in the nested monad;  if it returns 'Nothing',
        then it acts like 'mzero',  if it returns 'Just x', then it caches the
        result.
     -}
    runAndCacheMaybe :: Serialize x ⇒ (NestedMonad m) (Maybe x) → m x

--------------------------------------------------------------------------------
---------------------------------- Instances -----------------------------------
--------------------------------------------------------------------------------

{-| The 'Alternative' instance functions like the 'MonadPlus' instance. -}
instance Monad m ⇒ Alternative (TreeT m) where
    empty = mzero
    (<|>) = mplus

{-| Two trees are equal if they have the same structure. -}
instance Eq α ⇒ Eq (Tree α) where
    (TreeT x) == (TreeT y) = e x y
      where
        e x y = case (view x, view y) of
            (Return x, Return y) → x == y
            (Null :>>= _, Null :>>= _) → True
            (Cache cx :>>= kx, Cache cy :>>= ky) →
                case (runIdentity cx, runIdentity cy) of
                    (Nothing, Nothing) → True
                    (Just x, Just y) → e (kx x) (ky y)
                    _ → False
            (Choice (TreeT ax) (TreeT bx) :>>= kx, Choice (TreeT ay) (TreeT by) :>>= ky) →
                e (ax >>= kx) (ay >>= ky) && e (bx >>= kx) (by >>= ky)
            _  → False

{-| For this type, 'mplus' creates a branch node with a choice between two
    subtrees and 'mzero' aborts the tree.
 -}
instance Monad m ⇒ MonadPlus (TreeT m) where
    mzero = TreeT . singleton $ Null
    left `mplus` right = TreeT . singleton $ Choice left right

{-| This instance performs no caching but is provided to make it easier to test
    running a tree using the List monad.
 -}
instance MonadExplorable [] where
    cacheMaybe = maybe mzero return

{-| This instance performs no caching but is provided to make it easier to test
    running a tree using the 'ListT' monad.
 -}
instance Monad m ⇒ MonadExplorable (ListT m) where
    cacheMaybe = maybe mzero return

{-| Like the 'MonadExplorable' isntance, this instance does no caching. -}
instance Monad m ⇒ MonadExplorableTrans (ListT m) where
    type NestedMonad (ListT m) = m
    runAndCacheMaybe = lift >=> maybe mzero return

{-| This instance performs no caching but is provided to make it easier to test
    running a tree using the 'Maybe' monad.
 -}
instance MonadExplorable Maybe where
    cacheMaybe = maybe mzero return

{-| This instance performs no caching but is provided to make it easier to test
    running a tree using the 'MaybeT' monad.
 -}
instance Monad m ⇒ MonadExplorable (MaybeT m) where
    cacheMaybe = maybe mzero return

{-| Like the 'MonadExplorable' isntance, this instance does no caching. -}
instance Monad m ⇒ MonadExplorableTrans (MaybeT m) where
    type NestedMonad (MaybeT m) = m
    runAndCacheMaybe = lift >=> maybe mzero return

instance Monad m ⇒ MonadExplorable (TreeT m) where
    cache = runAndCache . return
    cacheGuard = runAndCacheGuard . return
    cacheMaybe = runAndCacheMaybe . return

instance Monad m ⇒ MonadExplorableTrans (TreeT m) where
    type NestedMonad (TreeT m) = m
    runAndCache = runAndCacheMaybe . liftM Just
    runAndCacheGuard = runAndCacheMaybe . liftM (\x → if x then Just () else Nothing)
    runAndCacheMaybe = TreeT . singleton . Cache

{-| This instance allows you to automatically get a MonadExplorable instance for
    any monad transformer that has `MonadPlus` defined.  (Unfortunately its
    presence requires OverlappingInstances because it overlaps with the instance
    for `TreeT`, even though the constraints are such that it is impossible
    in practice for there to ever be a case where a given type is satisfied by
    both instances.)
 -}
instance (MonadTrans t, MonadExplorable m, MonadPlus (t m)) ⇒ MonadExplorable (t m) where
    cache = lift . cache
    cacheGuard = lift . cacheGuard
    cacheMaybe = lift . cacheMaybe

instance MonadTrans TreeT where
    lift = TreeT . lift

{-| The 'Monoid' instance acts like the 'MonadPlus' instance. -}
instance Monad m ⇒ Monoid (TreeT m α) where
    mempty = mzero
    mappend = mplus
    mconcat = msum

instance Show α ⇒ Show (Tree α) where
    show = s . unwrapTreeT
      where
        s x = case view x of
            Return x → show x
            Null :>>= _ → "<NULL> >>= (...)"
            Cache c :>>= k →
                case runIdentity c of
                    Nothing → "NullCache"
                    Just x → "Cache[" ++ (show . encode $ x) ++ "] >>= " ++ (s (k x))
            Choice (TreeT a) (TreeT b) :>>= k → "(" ++ (s (a >>= k)) ++ ") | (" ++ (s (b >>= k)) ++ ")"


--------------------------------------------------------------------------------
---------------------------------- Functions -----------------------------------
--------------------------------------------------------------------------------

{- $functions
There are three kinds of functions in this module: functions which explore trees
in various ways, functions to make it easier to build trees, and a function
which changes the base monad of a pure tree.
 -}

---------------------------------- Explorers -----------------------------------

{- $runners
The following functions all take a tree as input and produce the result
of exploring it as output. There are seven functions because there are two kinds
of trees -- pure and impure -- and three ways of exploring a tree --
exploring everything and summing all results (i.e., in the leaves), exploring
until the first result (i.e., in a leaf) is encountered and immediately
returning, and gathering results (i.e., from the leaves) until they satisfy a
condition and then return -- plus a seventh function that explores a tree only
for the side-effects.
 -}

{-| Explores all the nodes in a pure tree and sums over all the
    results in the leaves.
 -}
exploreTree ::
    Monoid α ⇒
    Tree α {-^ the (pure) tree to be explored -} →
    α {-^ the sum over all results -}
exploreTree v =
    case view (unwrapTreeT v) of
        Return !x → x
        (Cache mx :>>= k) → maybe mempty (exploreTree . TreeT . k) (runIdentity mx)
        (Choice left right :>>= k) →
            let !x = exploreTree $ left >>= TreeT . k
                !y = exploreTree $ right >>= TreeT . k
                !xy = mappend x y
            in xy
        (Null :>>= _) → mempty
{-# INLINEABLE exploreTree #-}

{-| Explores all the nodes in an impure tree and sums over all the
    results in the leaves.
 -}
exploreTreeT ::
    (Monad m, Monoid α) ⇒
    TreeT m α {-^ the (impure) tree to be explored -} →
    m α {-^ the sum over all results -}
exploreTreeT = viewT . unwrapTreeT >=> \view →
    case view of
        Return !x → return x
        (Cache mx :>>= k) → mx >>= maybe (return mempty) (exploreTreeT . TreeT . k)
        (Choice left right :>>= k) →
            liftM2 (\(!x) (!y) → let !xy = mappend x y in xy)
                (exploreTreeT $ left >>= TreeT . k)
                (exploreTreeT $ right >>= TreeT . k)
        (Null :>>= _) → return mempty
{-# SPECIALIZE exploreTreeT :: Monoid α ⇒ Tree α → Identity α #-}
{-# SPECIALIZE exploreTreeT :: Monoid α ⇒ TreeIO α → IO α #-}
{-# INLINEABLE exploreTreeT #-}

{-| Explores a tree for its side-effects, ignoring all results. -}
exploreTreeTAndIgnoreResults ::
    Monad m ⇒
    TreeT m α {-^ the (impure) tree to be explored -} →
    m ()
exploreTreeTAndIgnoreResults = viewT . unwrapTreeT >=> \view →
    case view of
        Return _ → return ()
        (Cache mx :>>= k) → mx >>= maybe (return ()) (exploreTreeTAndIgnoreResults . TreeT . k)
        (Choice left right :>>= k) → do
            exploreTreeTAndIgnoreResults $ left >>= TreeT . k
            exploreTreeTAndIgnoreResults $ right >>= TreeT . k
        (Null :>>= _) → return ()
{-# SPECIALIZE exploreTreeTAndIgnoreResults :: Tree α → Identity () #-}
{-# SPECIALIZE exploreTreeTAndIgnoreResults :: TreeIO α → IO () #-}
{-# INLINEABLE exploreTreeTAndIgnoreResults #-}

{-| Explores all the nodes in a tree until a result (i.e., a leaf) has been
    found; if a result has been found then it is returned wrapped in 'Just',
    otherwise 'Nothing' is returned.
 -}
exploreTreeUntilFirst ::
    Tree α {-^ the (pure) tree to be explored -} →
    Maybe α {-^ the first result found, if any -}
exploreTreeUntilFirst v =
    case view (unwrapTreeT v) of
        Return x → Just x
        (Cache mx :>>= k) → maybe Nothing (exploreTreeUntilFirst . TreeT . k) (runIdentity mx)
        (Choice left right :>>= k) →
            let x = exploreTreeUntilFirst $ left >>= TreeT . k
                y = exploreTreeUntilFirst $ right >>= TreeT . k
            in if isJust x then x else y
        (Null :>>= _) → Nothing
{-# INLINEABLE exploreTreeUntilFirst #-}

{-| Same as 'exploreTreeUntilFirst', but taking an impure tree instead
    of pure one.
 -}
exploreTreeTUntilFirst ::
    Monad m ⇒
    TreeT m α {-^ the (impure) tree to be explored -} →
    m (Maybe α) {-^ the first result found, if any -}
exploreTreeTUntilFirst = viewT . unwrapTreeT >=> \view →
    case view of
        Return !x → return (Just x)
        (Cache mx :>>= k) → mx >>= maybe (return Nothing) (exploreTreeTUntilFirst . TreeT . k)
        (Choice left right :>>= k) → do
            x ← exploreTreeTUntilFirst $ left >>= TreeT . k
            if isJust x
                then return x
                else exploreTreeTUntilFirst $ right >>= TreeT . k
        (Null :>>= _) → return Nothing
{-# SPECIALIZE exploreTreeTUntilFirst :: Tree α → Identity (Maybe α) #-}
{-# SPECIALIZE exploreTreeTUntilFirst :: TreeIO α → IO (Maybe α) #-}
{-# INLINEABLE exploreTreeTUntilFirst #-}

{-| Explores all the nodes in a tree, summing all encountered results (i.e., in
    the leaves) until the current partial sum satisfies the condition provided
    by the first function; if this condition is ever satisfied then its result
    is returned in 'Right', otherwise the final sum is returned in 'Left'.
 -}
exploreTreeUntilFound ::
    Monoid α ⇒
    (α → Maybe β) {-^ a function that determines when the desired results have
                      been found;  'Nothing' will cause the search to continue
                      whereas returning 'Just' will cause the search to stop and
                      the value in the 'Just' to be returned wrappedi n 'Right'
                   -} →
    Tree α {-^ the (pure) tree to be explored -} →
    Either α β {-^ if no acceptable results were found, then 'Left' with the sum
                   over all results;  otherwise 'Right' with the value returned
                   by the function in the first argument
                -}
exploreTreeUntilFound f v =
    case view (unwrapTreeT v) of
        Return x → runThroughFilter x
        (Cache mx :>>= k) →
            maybe (Left mempty) (exploreTreeUntilFound f . TreeT . k)
            $
            runIdentity mx
        (Choice left right :>>= k) →
            let x = exploreTreeUntilFound f $ left >>= TreeT . k
                y = exploreTreeUntilFound f $ right >>= TreeT . k
            in case (x,y) of
                (result@(Right _),_) → result
                (_,result@(Right _)) → result
                (Left a,Left b) → runThroughFilter (a <> b)
        (Null :>>= _) → Left mempty
  where
    runThroughFilter x = maybe (Left x) Right . f $ x

{-| Same as 'exploreTreeUntilFound', but taking an impure tree instead of
    a pure tree.
 -}
exploreTreeTUntilFound ::
    (Monad m, Monoid α) ⇒
    (α → Maybe β) {-^ a function that determines when the desired results have
                      been found;  'Nothing' will cause the search to continue
                      whereas returning 'Just' will cause the search to stop and
                      the value in the 'Just' to be returned wrappedi n 'Right'
                   -} →
    TreeT m α {-^ the (impure) tree to be explored -} →
    m (Either α β) {-^ if no acceptable results were found, then 'Left' with the
                       sum over all results;  otherwise 'Right' with the value
                       returned by the function in the first argument
                    -}
exploreTreeTUntilFound f = viewT . unwrapTreeT >=> \view →
    case view of
        Return x → runThroughFilter x
        (Cache mx :>>= k) →
            mx
            >>=
            maybe (return (Left mempty)) (exploreTreeTUntilFound f . TreeT . k)
        (Choice left right :>>= k) → do
            x ← exploreTreeTUntilFound f $ left >>= TreeT . k
            case x of
                result@(Right _) → return result
                Left a → do
                    y ← exploreTreeTUntilFound f $ right >>= TreeT . k
                    case y of
                        result@(Right _) → return result
                        Left b → runThroughFilter (a <> b)
        (Null :>>= _) → return (Left mempty)
  where
    runThroughFilter x = return . maybe (Left x) Right . f $ x

---------------------------------- Builders ------------------------------------

{- $builders
The following functions all create a tree from various inputs. The
convention for suffixes is as follows: No suffix means that the tree will be
built in a naive fashion using 'msum', which takes each item in the list and
'mplus'es it with the resut of the list --- that is

>   msum [a,b,c,d]

which is equivalent to

>   a `mplus` (b `mplus` (c `mplus` (d `mplus` mzero)))

The downside of this approach is that it produces an incredibly unbalanced tree,
which will degrade parallization;  this is because if the tree is too
unbalanced then the work-stealing algorithm will either still only a small
piece of the remaining workload or nearly all of the remaining workload, and in
both cases a processor will end up with a small amount of work to do before it
finishes and immediately needs to steal another workload from someone else.

Given that a balanced tree is desirable, the Balanced functions work by copying
the input list into an array, starting with a range that covers the whole array,
and then splitting the range at every choice point until eventually the range
has length 1, in which case the element of the array is read;  the result is an
optimally balanced tree.

The downside of the Balanced functions is that they need to process the whole
list at once rather than one element at a time. The BalancedBottomUp functions
use a different algorithm that takes 33% less time than the Balanced algorithm
by processing each element one at a time and building the result tree using a
bottom-up approach rather than a top-down approach. For details of this
algoithm, see "LogicGrowsOnTrees.Utils.MonadPlusForest"; note that it is also possible
to get a slight speed-up by using the data structures in
"LogicGrowsOnTrees.Utils.MonadPlusForest" directly rather than implicitly through the
BalancedBottomUp functions.

The odd function out in this section is 'between', which takes the lower and
upper bound if an input range and returns an optimally balanced tree generating
all of the results in the range.
 -}

{-| Returns a tree (or some other 'MonadPlus') with all of the results in the
    input list.

    WARNING: The returned tree will have the property that every branch has one
    element in the left branch and the remaining elements in the right branch,
    which is heavily unbalanced and does not parallelize well. You should
    consider using 'allFromBalanced' and 'allFromBalancedBottomUp instead.
 -}
allFrom ::
    (Foldable t, Functor t, MonadPlus m) ⇒
    t α {-^ the list (or some other Foldable) of results to generate -} →
    m α {-^ a tree that generates the given list of results -}
allFrom = Fold.msum . fmap return
{-# INLINE allFrom #-}

{-| Returns a tree that generates a tree with all of the results in the
    input list in an optimally balanced search tree.
 -}
allFromBalanced ::
    MonadPlus m ⇒
    [α] {-^ the list of results to generate in the resulting tree -} →
    m α {-^ an optimally balanced a tree that generates the given list of results -}
allFromBalanced [] = mzero
allFromBalanced x = go 0 end
  where
    end = length x - 1
    array = listArray (0,end) x

    go a b
      | a == b = return $ array ! a
      | otherwise = go a m `mplus` go (m+1) b
          where
            m = (a + b) `div` 2
{-# INLINE allFromBalanced #-}

{-| Returns a tree (or some other 'MonadPlus') that generates all of
    the results in the input list (or some other 'Foldable') in an approximately
    balanced tree with less overhead than 'allFromBalanced'; see the
    documentation for this section and/or "LogicGrowsOnTrees.Utils.MonadPlusForest" for
    more information about the exact
    algorithm used.
 -}
allFromBalancedBottomUp ::
    (Foldable t, MonadPlus m) ⇒
    t α {-^ the list (or some other Foldable) of results to generate -} →
    m α {-^ an approximately optimally balanced a tree that generates the given list of results -}
allFromBalancedBottomUp =
    consolidateForest
    .
    Fold.foldl
        (\(!forest) x → addToForest forest (return x))
        emptyForest
{-# INLINE allFromBalancedBottomUp #-}

{-| Returns an optimally balanced tree (or some other 'MonadPlus') that
    generates all of the elements in the given (inclusive) range; if the lower
    bound is greater than the upper bound it returns 'mzero'.
 -}
between ::
    (Enum n, MonadPlus m) ⇒
    n {-^ the (inclusive) lower bound of the range -} →
    n {-^ the (inclusive) upper bound of the range -} →
    m n {-^ a tree (or other 'MonadPlus') that generates all the results in the range -}
between x y =
    if a > b
        then mzero
        else go a b
  where
    a = fromEnum x
    b = fromEnum y

    go a b | a == b    = return (toEnum a)
    go a b | otherwise = go a (a+d) `mplus` go (a+d+1) b
      where
        d = (b-a) `div` 2
{-# INLINE between #-}

{-| Returns a tree (or some other 'MonadPlus') that merges all of the trees in
    the input list using an optimally balanced tree.
 -}
msumBalanced ::
    MonadPlus m ⇒
    [m α] {-^ the list of trees (or other 'MonadPlus's) to merge -} →
    m α {-^ the merged tree -}
msumBalanced [] = mzero
msumBalanced x = go 0 end
  where
    end = length x - 1
    array = listArray (0,end) x

    go a b
      | a == b = array ! a
      | otherwise = go a m `mplus` go (m+1) b
          where
            m = (a + b) `div` 2
{-# INLINE msumBalanced #-}

{-| Returns a tree (or some other 'MonadPlus') that merges all of the
    trees in the input list (or some other 'Foldable') using an
    approximately balanced tree with less overhead than 'msumBalanced'; see the
    documentation for this section and/or "LogicGrowsOnTrees.Utils.MonadPlusForest" for
    more information about the exact algorithm used.
 -}
msumBalancedBottomUp ::
    (Foldable t, MonadPlus m) ⇒
    t (m α) {-^ the list (or other 'Foldable') of trees (or other 'MonadPlus's) to merge -} →
    m α {-^ the merged tree -}
msumBalancedBottomUp =
    consolidateForest
    .
    Fold.foldl
        (\(!forest) x → addToForest forest x)
        emptyForest
{-# INLINE msumBalancedBottomUp #-}

-------------------------------- Transformers ----------------------------------

{-| This function lets you take a pure tree and transform it into a
    tree with an arbitrary base monad.
 -}
endowTree ::
    Monad m ⇒
    Tree α {-^ the pure tree to transformed into an impure tree -} →
    TreeT m α {-^ the resulting impure tree -}
endowTree tree =
    case view . unwrapTreeT $ tree of
        Return x → return x
        Cache mx :>>= k →
            cacheMaybe (runIdentity mx) >>= endowTree . TreeT . k
        Choice left right :>>= k →
            mplus
                (endowTree left >>= endowTree . TreeT . k)
                (endowTree right >>= endowTree . TreeT . k)
        Null :>>= _ → mzero


--------------------------------------------------------------------------------
------------------------------- Implementation ---------------------------------
--------------------------------------------------------------------------------

{- $implementation
The implementation of the 'Tree' types uses the approach described in
"The Operational Monad Tutorial", published in Issue 15 of The Monad.Reader at
<http://themonadreader.wordpress.com/>;  specifically it uses the `operational`
package.  The idea is that a list of instructions are provided in
'TreeTInstruction', and then the operational monad does all the heavy lifting
of turning them into a monad.
 -}

{-| The core of the implementation of 'Tree' is mostly contained in this
    type, which provides a list of primitive instructions for trees:
    'Cache', which caches a value, 'Choice', which signals a branch with two
    choices, and 'Null', which indicates that there are no more results.
 -}
data TreeTInstruction m α where
    Cache :: Serialize α ⇒ m (Maybe α) → TreeTInstruction m α
    Choice :: TreeT m α → TreeT m α → TreeTInstruction m α
    Null :: TreeTInstruction m α

{-| This is just a convenient alias for working with pure tree. -}
type TreeInstruction = TreeTInstruction Identity