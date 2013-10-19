{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}

{-| This module provides a framework for creating a program that explores a tree
    in parallel. There are two families of functions that are available. The
    first is more general and allows you to construct your tree using arguments
    given on the command-line; they are described in the section linked to by
    "LogicGrowsOnTrees.Parallel.Main#main". If you do not need run-time
    information via a command-line argument to construct the tree, then you may
    prefer the simpler family of functions which are described in the section
    linked to by "LogicGrowsOnTrees.Parallel.Main#main-simple".

    All of this functionality is adapter independent, so if you want to use a
    different back end you only need to change the driver argument and
    recompile.
 -}
module LogicGrowsOnTrees.Parallel.Main
    (
    -- * Types
    -- ** Driver types
      Driver(..)
    , DriverParameters(..)
    -- ** Outcome types
    , RunOutcome(..)
    , RunOutcomeFor
    , RunStatistics(..)
    , TerminationReason(..)
    , TerminationReasonFor
    -- * Main functions
    -- $main

    -- ** Sum over all results
    -- $all
    , mainForExploreTree
    , mainForExploreTreeIO
    , mainForExploreTreeImpure
    -- ** Stop at first result
    -- $first
    , mainForExploreTreeUntilFirst
    , mainForExploreTreeIOUntilFirst
    , mainForExploreTreeImpureUntilFirst
    -- ** Stop when sum of results found
    -- $found

    -- *** Pull
    -- $pull
    , mainForExploreTreeUntilFoundUsingPull
    , mainForExploreTreeIOUntilFoundUsingPull
    , mainForExploreTreeImpureUntilFoundUsingPull
    -- *** Push
    -- $push
    , mainForExploreTreeUntilFoundUsingPush
    , mainForExploreTreeIOUntilFoundUsingPush
    , mainForExploreTreeImpureUntilFoundUsingPush
    -- ** Generic main function
    , genericMain
    -- * Simple main functions
    -- $main-simple

    -- ** Sum over all results
    -- $all-simple
    , simpleMainForExploreTree
    , simpleMainForExploreTreeIO
    , simpleMainForExploreTreeImpure
    -- ** Stop at first result
    -- $first-simple
    , simpleMainForExploreTreeUntilFirst
    , simpleMainForExploreTreeIOUntilFirst
    , simpleMainForExploreTreeImpureUntilFirst
    -- ** Stop when sum of results found
    -- $found-simple

    -- *** Pull
    -- $pull-simple
    , simpleMainForExploreTreeUntilFoundUsingPull
    , simpleMainForExploreTreeIOUntilFoundUsingPull
    , simpleMainForExploreTreeImpureUntilFoundUsingPull
    -- *** Push
    -- $push-simple
    , simpleMainForExploreTreeUntilFoundUsingPush
    , simpleMainForExploreTreeIOUntilFoundUsingPush
    , simpleMainForExploreTreeImpureUntilFoundUsingPush
    -- * Utility functions
    , extractRunOutcomeFromSupervisorOutcome
    , mainParser
    ) where

import Prelude hiding (catch,readFile,writeFile)

import Control.Applicative ((<$>),(<*>),pure)
import Control.Arrow ((&&&))
import Control.Concurrent (ThreadId,threadDelay)
import Control.Exception (SomeException,finally,handleJust,onException)
import Control.Monad (forM_,forever,join,liftM,liftM2,mplus,when,unless,void)
import Control.Monad.CatchIO (catch)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Tools (ifM)

import Data.ByteString.Lazy (readFile,writeFile)
import Data.Char (toLower)
import Data.Composition ((.*),(.**))
import Data.Derive.Serialize
import Data.DeriveTH
import Data.Function (on)
import Data.Functor.Identity (Identity)
import Data.IORef (IORef,newIORef,readIORef,writeIORef)
import Data.List (find,intercalate,nub)
import Data.List.Split (splitOn)
import Data.Monoid (Monoid(..))
import Data.Ord (comparing)
import Data.Prefix.Units (FormatMode(FormatSiAll),formatValue,unitName)
import Data.Serialize
import Data.Time.Clock (NominalDiffTime)

import System.Console.CmdTheLine
import System.Directory (doesFileExist,removeFile,renameFile)
import System.Environment (getProgName)
import System.IO (hFlush,hPutStrLn,stderr,stdout)
import System.IO.Error (isDoesNotExistError)
import qualified System.Log.Logger as Logger
import System.Log.Formatter (simpleLogFormatter)
import System.Log.Handler (setFormatter)
import System.Log.Handler.Simple (streamHandler)
import System.Log.Logger (Priority(..),logM,rootLoggerName,setHandlers,setLevel,updateGlobalLogger)
import System.Log.Logger.TH

import Text.PrettyPrint (text)
import Text.Printf (printf)

import LogicGrowsOnTrees (Tree,TreeIO,TreeT)
import LogicGrowsOnTrees.Checkpoint
import LogicGrowsOnTrees.Parallel.Common.RequestQueue
import LogicGrowsOnTrees.Parallel.Common.Supervisor
    ( FunctionOfTimeStatistics(..)
    , IndependentMeasurementsStatistics(..)
    , RunStatistics(..)
    , SupervisorTerminationReason(..)
    , SupervisorOutcome(..)
    )
import LogicGrowsOnTrees.Parallel.ExplorationMode
import LogicGrowsOnTrees.Parallel.Purity

--------------------------------------------------------------------------------
----------------------------------- Loggers ------------------------------------
--------------------------------------------------------------------------------

deriveLoggers "Logger" [INFO,NOTICE,ERROR]

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

type Tense = String → String → String

---------------------------------- Statistic -----------------------------------

data Statistic = Statistic
    {   statisticLongName :: String
    ,   statisticShortName :: String
    ,   statisticDescription :: String
    ,   statisticApplication :: Tense → RunStatistics → String
    }
instance Eq Statistic where
    (==) = (==) `on` statisticLongName
instance Ord Statistic where
    compare = comparing statisticLongName

-------------------------------- Configuration ---------------------------------

data CheckpointConfiguration = CheckpointConfiguration
    {   checkpoint_path :: FilePath
    ,   checkpoint_interval :: Float
    } deriving (Eq,Show)

data LoggingConfiguration = LoggingConfiguration
    {   log_level :: Priority
    ,   maybe_log_format :: Maybe String
    } deriving (Eq,Show)
instance Serialize Priority where
    put = put . show
    get = read <$> get
$( derive makeSerialize ''LoggingConfiguration )

data StatisticsConfiguration = StatisticsConfiguration
    {   end_stats_configuration :: [[Statistic]]
    ,   log_end_stats_configuration :: Bool
    ,   log_stats_configuration :: [[Statistic]]
    ,   log_stats_level_configuration :: Priority
    ,   log_stats_interval_configuration :: Float
    }

data SupervisorConfiguration = SupervisorConfiguration
    {   maybe_checkpoint_configuration :: Maybe CheckpointConfiguration
    ,   maybe_workload_buffer_size_configuration :: Maybe Int
    ,   statistics_configuration :: StatisticsConfiguration
    ,   show_cpu_time :: Bool
    }

data SharedConfiguration tree_configuration = SharedConfiguration
    {   logging_configuration :: LoggingConfiguration
    ,   tree_configuration :: tree_configuration
    } deriving (Eq,Show)
$( derive makeSerialize ''SharedConfiguration )

data ProgressAndCPUTime progress = ProgressAndCPUTime progress Rational
$( derive makeSerialize ''ProgressAndCPUTime )

--------------------------------- Driver types ---------------------------------

{-| The 'Driver' is the core type that abstracts the various adapters behind a
    common interface that can be invoked by the main functions; it specifies a
    function that is called to start the run with a set of parameters specified
    in 'DriverParameters'.

    (Unfortunately in haddock the type signature below can be difficult to read
    because it puts all of the type on a single line; the type is essentially
    just a map from 'DriverParameters' to @result_monad ()@, but involving a
    bunch of type variables and some constraints on them. It might be easier to
    click the link to go to the source.)

    Note that the @controller_monad@ type parameter is within an existential
    type; this is because the user of the driver should not need to know what it
    is.
 -}
data Driver
    result_monad
    shared_configuration
    supervisor_configuration
    m n
    exploration_mode
  = ∀ controller_monad.
    ( RequestQueueMonad (controller_monad exploration_mode)
    , ExplorationModeFor (controller_monad exploration_mode) ~ exploration_mode
    ) ⇒
    Driver (
        ( Serialize (ProgressFor exploration_mode)
        , MonadIO result_monad
        ) ⇒
        DriverParameters
            shared_configuration
            supervisor_configuration
            m n
            exploration_mode
            controller_monad
        → result_monad ()
    )

{-| The 'DriverParameters' type specifies the information that is given to the
    driver in the main functions.
 -}
data DriverParameters
    shared_configuration
    supervisor_configuration
    m n
    exploration_mode
    controller_monad =
    DriverParameters
    {   {-| configuration information shared between the supervisor and the worker -}
        shared_configuration_term :: Term shared_configuration
        {-| configuration information specific to the supervisor -}
    ,   supervisor_configuration_term :: Term supervisor_configuration
        {-| program information;  should at a minimum put a brief description of the program in the 'termDoc' field -}
    ,   program_info :: TermInfo
        {-| action that initializes the global state of each process --- that
            is, once for each running instance of the executable, which
            depending on the adapter might be a supervisor, a worker, or both
         -}
    ,   initializeGlobalState :: shared_configuration → IO ()
        {-| in the supervisor, gets the starting progress for the exploration;  this is where a checkpoint is loaded, if one exists -}
    ,   getStartingProgress :: shared_configuration → supervisor_configuration → IO (ProgressFor exploration_mode)
        {-| in the supervisor, responds to the termination of the run -}
    ,   notifyTerminated :: shared_configuration → supervisor_configuration → RunOutcomeFor exploration_mode → IO ()
        {-| constructs the exploration mode given the shared configuration -}
    ,   constructExplorationMode :: shared_configuration → ExplorationMode exploration_mode
        {-| constructs the tree given the shared configuration -}
    ,   constructTree :: shared_configuration → TreeT m (ResultFor exploration_mode)
        {-| the purity of the constructed tree -}
    ,   purity :: Purity m n
        {-| construct the controller, which runs in the supervisor and handles things like periodic checkpointing -}
    ,   constructController :: shared_configuration → supervisor_configuration → controller_monad exploration_mode ()
    }

-------------------------------- Outcome types ---------------------------------

{-| A type that represents the outcome of a run. -}
data RunOutcome progress final_result = RunOutcome
    {   {-| statistics gathered during the run, useful if the system is not scaling with the number of workers as it should -}
        runStatistics :: RunStatistics
        {-| the reason why the run terminated -}
    ,   runTerminationReason :: TerminationReason progress final_result
    } deriving (Eq,Show)

{-| A convenient type alias for the type of 'RunOutcome' associated with the given exploration mode. -}
type RunOutcomeFor exploration_mode = RunOutcome (ProgressFor exploration_mode) (FinalResultFor exploration_mode)

{-| A type that represents the reason why a run terminated. -}
data TerminationReason progress final_result =
    {-| the run was aborted with the given progress -}
    Aborted progress
    {-| the run completed with the given final result -}
  | Completed final_result
    {-| the run failed with the given progress for the given reason -}
  | Failure progress String
  deriving (Eq,Show)

{-| A convenient type alias for the type of 'TerminationReason' associated with the given exploration mode. -}
type TerminationReasonFor exploration_mode = TerminationReason (ProgressFor exploration_mode) (FinalResultFor exploration_mode)

--------------------------------------------------------------------------------
---------------------------------- Instances -----------------------------------
--------------------------------------------------------------------------------

instance ArgVal Priority where
    converter = enum $
        [DEBUG,INFO,NOTICE,WARNING,ERROR,CRITICAL,ALERT,EMERGENCY]
        >>=
        \level → let name = show level
                 in return (name,level) `mplus` return (map toLower name,level)

instance ArgVal [Statistic] where
    converter = (parse,pretty)
      where
        parse = go [] . splitOn ","
          where
            go stats [] = Right . reverse . nub $ stats
            go _ ("all":_) = Right statistics
            go stats (name:rest) =
                case find (\Statistic{..} → statisticLongName == name || statisticShortName == name) statistics of
                    Just stat → go (stat:stats) rest
                    Nothing → Left . text $ "unrecognized statistic '" ++ show name ++ "'"
        pretty stats
          | length stats == length statistics = text "all"
          | otherwise = text . intercalate "," . map statisticLongName $ stats

--------------------------------------------------------------------------------
-------------------------------- Main functions --------------------------------
--------------------------------------------------------------------------------

{- $main #main#
The functions in this section all provide a main function that starts up the
system that explores a tree in parallel using the given tree (constructed
possibly using information supplied on the command line) and the given adapter
provided via the driver argument.

All of the functionality of this module can be accessed through 'genericMain',
but we nonetheless also provide specialized versions of these functions for all
of the supported tree purities and exploration modes. This is done for two
reasons: first, in order to make the types more concrete to hopefully improve
usability, and second, because often the type of the tree is generalized so it
could be one of several types, and using a specialized function automatically
specializes the type rather than requiring a type annotation. The convention is
@mainForExploreTreeXY@ where @X@ is empty for pure trees, @IO@ for trees with
side-effects in the `IO` monad, and @Impure@ for trees with side-effects in some
general monad, and @Y@ specifies the exploration mode, which is empty for
'AllMode' (sum over all results), @UntilFirst@ for 'FirstMode' (stop when first
result found), @UntilFoundUsingPull@ for 'FoundModeUsingPull' (sum all results
until a condition has been met, only sending results to the supervisor upon
request) and @UntilFoundUsingPush@ for 'FoundModeUsingPush' (sum all results
until a condition has been met, pushing all found results immediately to the
supervisor).

If you do not need to use command-line arguments to construct the tree and don't
care about what the name of the program is on the help screen then you might be
interested in the simpler version of these functions in the following section
(follow "LogicGrowsOnTrees.Parallel.Main#main-simple").
 -}
 
---------------------------- Sum over all results ------------------------------

{- $all #all#
The functions in this section are for when you want to sum over all the results
in (the leaves of) the tree.
 -}

{-| Explore the given pure tree in parallel; the results in the leaves will be
    summed up using the 'Monoid' instance.
 -}
mainForExploreTree ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration Identity IO (AllMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) result → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → Tree result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTree = genericMain (const AllMode) Pure
{-# INLINE mainForExploreTree #-}

{-| Explore the given IO tree in parallel; the results in the leaves will be
    summed up using the 'Monoid' instance.
 -}
mainForExploreTreeIO ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration IO IO (AllMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) result → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeIO result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeIO = genericMain (const AllMode) io_purity
{-# INLINE mainForExploreTreeIO #-}

{-| Explore the given impure tree in parallel; the results in all of the leaves
    will be summed up using the 'Monoid' instance.
 -}
mainForExploreTreeImpure ::
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration m m (AllMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) result → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeT m result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeImpure = genericMain (const AllMode) . ImpureAtopIO
{-# INLINE mainForExploreTreeImpure #-}

---------------------------- Stop at first result ------------------------------

{- $first #first#
The functions in this section are for when you want to stop as soon as you have
found a result.

There are two ways in which a system running in this mode can terminate normally:

    1. A solution is found, in which case a 'Just'-wrapped value is returned
       with both the found solution and the current 'Checkpoint', the latter
       allowing one to resume the search to look for more solutions later.

    2. The whole tree has been explored, in which case 'Nothing' is returned.

 -}

{-| Explore the given pure tree in parallel, stopping if a solution is found. -}
mainForExploreTreeUntilFirst ::
    (Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration Identity IO (FirstMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome Checkpoint (Maybe (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → Tree result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeUntilFirst = genericMain (const FirstMode) Pure
{-# INLINE mainForExploreTreeUntilFirst #-}

{-| Explore the given IO tree in parallel, stopping if a solution is found. -}
mainForExploreTreeIOUntilFirst ::
    (Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration IO IO (FirstMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome Checkpoint (Maybe (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeIO result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeIOUntilFirst = genericMain (const FirstMode) io_purity
{-# INLINE mainForExploreTreeIOUntilFirst #-}

{-| Explore the given impure tree in parallel, stopping if a solution is found. -}
mainForExploreTreeImpureUntilFirst ::
    (Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration m m (FirstMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome Checkpoint (Maybe (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeT m result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeImpureUntilFirst = genericMain (const FirstMode) . ImpureAtopIO
{-# INLINE mainForExploreTreeImpureUntilFirst #-}

------------------- Stop when sum of results meets condition -------------------

{- $found #found#
The functions in this section are for when you want sum the results as you find
them until the sum matches a condition.  There are two versions of this mode,
based on whether one wants to regularly poll the workers for results or whether
one wants workers to immediately push every result to the supervisor as soon as
it is found.
 -}

{- $pull #pull#
In this mode, partial results are left on the workers until they receive either
a workload steal request or a progress update request. The advantage of this
approach is that it minimizes communication costs as partial results are sent on
an occasional basis rather than as soon as they are found. The downside of this
approach is that one has to poll the workers on a regular basis using a global
process update, and between polls it might be the case that the sum of all
results in the system meets the condition but this will not be found out until
the next poll, which wastes time equal to the amount of time between polls. If
you would rather have the system immediately terminate as soon as it has found
the desired results (at the price of paying an additional cost as each workload
is found in sending it to the supervisor), then follow
"LogicGrowsOnTrees.Parallel.Main#push" to see the description of push mode.

There are three ways in which a system running in this mode can terminate:

    1. A worker finds another result and now its (new) local sum meet the
       condition; in this case the sum of the worker's local sum and the
       supervisor's local sum is returned along with the current checkpoint
       (which allows the search to be resumed later to find more results), all
       wrapped in a 'Right'.

    2. The supervisor, having just received some new results from a worker, has
       its (new) local sum meet the condition; this has essentially the same
       effect as 1.

    3. The tree has been fully explored, in which case the full sum is returned
       in a 'Left'.

WARNING:  If you use this mode then you need to enable checkpointing when the
          program is run; if you do not do this, then you might end up in a
          situation where the sum of results over the entire system meets the
          condition but the system does not realize this because the results
          have not been gathered together and summed at the supervisor.
 -}

{-| Explore the given pure tree in parallel until the sum of results meets the
    given condition.
 -}
mainForExploreTreeUntilFoundUsingPull ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (tree_configuration → result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration Identity IO (FoundModeUsingPull result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → Tree result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeUntilFoundUsingPull constructCondition = genericMain (FoundModeUsingPull . constructCondition) Pure
{-# INLINE mainForExploreTreeUntilFoundUsingPull #-}

{-| Explore the given IO tree in parallel until the sum of results meets the
    given condition.
 -}
mainForExploreTreeIOUntilFoundUsingPull ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (tree_configuration → result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration IO IO (FoundModeUsingPull result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeIO result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeIOUntilFoundUsingPull constructCondition = genericMain (FoundModeUsingPull . constructCondition) io_purity
{-# INLINE mainForExploreTreeIOUntilFoundUsingPull #-}

{-| Explore the given impure tree in parallel until the sum of results meets the
    given condition.
 -}
mainForExploreTreeImpureUntilFoundUsingPull ::
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (tree_configuration → result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration m m (FoundModeUsingPull result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeT m result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeImpureUntilFoundUsingPull constructCondition = genericMain (FoundModeUsingPull . constructCondition) . ImpureAtopIO
{-# INLINE mainForExploreTreeImpureUntilFoundUsingPull #-}

{- $push #push#
In this mode, whenever a result is found it is immediately sent to the
supervisor. The advantage of this approach is that the system finds out
immediately when all the results found so far have met the condition, rather
than waiting for a progress update to occur that gathers them together. The
downside of this approach is that it costs some time for a worker to send a
result to the supervisor, so if the condition will not be met until a large
number of results have been found then it be better let the workers accumulate
results locally and to poll them on a regular basis; to do this, follow
"LogicGrowsOnTrees.Parallel.Main#pull" to see the description of pull mode.

There are three ways in which a system running in this mode can terminate:

    1. The supervisor, having just received a new result from a worker, finds
       that its current sum meets the condition function, in which case it
       returns the sum as well as the current checkpoint (which allows the
       search to be resumed later to find more results) wrapped in a 'Right'.

    2. The tree has been fully explored, in which case the full sum is returned
       in a 'Left'.

(Note that, unlike the pull version, a partial result will not be returned upon
success as the Supervisor has access to all results and so it will never be in
the position of only having a partial result upon success.)
 -}

{-| Explore the given pure tree in parallel until the sum of results meets the
    given condition.
 -}
mainForExploreTreeUntilFoundUsingPush ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (tree_configuration → result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration Identity IO (FoundModeUsingPush result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → Tree result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeUntilFoundUsingPush constructCondition = genericMain (FoundModeUsingPush . constructCondition) Pure
{-# INLINE mainForExploreTreeUntilFoundUsingPush #-}

{-| Explore the given IO tree in parallel until the sum of results meets the
    given condition.
 -}
mainForExploreTreeIOUntilFoundUsingPush ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (tree_configuration → result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration IO IO (FoundModeUsingPush result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeIO result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeIOUntilFoundUsingPush constructCondition = genericMain (FoundModeUsingPush . constructCondition) io_purity
{-# INLINE mainForExploreTreeIOUntilFoundUsingPush #-}

{-| Explore the given impure tree in parallel until the sum of results meets the
    given condition.
 -}
mainForExploreTreeImpureUntilFoundUsingPush ::
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (tree_configuration → result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration tree_configuration) SupervisorConfiguration m m (FoundModeUsingPush result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeT m result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
mainForExploreTreeImpureUntilFoundUsingPush constructCondition = genericMain (FoundModeUsingPush . constructCondition) . ImpureAtopIO
{-# INLINE mainForExploreTreeImpureUntilFoundUsingPush #-}

--------------------------------------------------------------------------------
-------------------------- Simplified main functions ---------------------------
--------------------------------------------------------------------------------

{- $main-simple #main-simple#
The functions in this section provide simpler version of the functions in the
preceding section (follow "LogicGrowsOnTrees.Parallel.Main#main") for the case
where you do not need to use command-line arguments to construct the tree and
don't care about what the name of the program is on the help screen; the naming
convention follows the same convention as that in the previous section.
 -}

---------------------------- Sum over all results ------------------------------

{- $all-simple
The functions in this section are for when you want to sum over all the results
in (the leaves of) the tree.
 -}

{-| Explore the given pure tree in parallel; the results
    in the leaves will be summed up using the 'Monoid' instance.
 -}
simpleMainForExploreTree ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration Identity IO (AllMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) result → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    Tree result {-^ the tree to explore -} →
    result_monad ()
simpleMainForExploreTree = dispatchToMainFunction mainForExploreTree
{-# INLINE simpleMainForExploreTree #-}

{-| Explore the given IO tree in parallel;
    the results in the leaves will be summed up using the 'Monoid' instance.
 -}
simpleMainForExploreTreeIO ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration IO IO (AllMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) result → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeIO result {-^ the tree to explore in IO -} →
    result_monad ()
simpleMainForExploreTreeIO = dispatchToMainFunction mainForExploreTreeIO
{-# INLINE simpleMainForExploreTreeIO #-}

{-| Explore the given impure tree in parallel; the
    results in all of the leaves will be summed up using the 'Monoid' instance.
 -}
simpleMainForExploreTreeImpure ::
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration m m (AllMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) result → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeT m result {-^ the (impure) tree to explore -} →
    result_monad ()
simpleMainForExploreTreeImpure = dispatchToMainFunction . mainForExploreTreeImpure
{-# INLINE simpleMainForExploreTreeImpure #-}

---------------------------- Stop at first result ------------------------------

{- $first-simple
For more details, follow this link: "LogicGrowsOnTrees.Parallel.Main#first"
 -}

{-| Explore the given pure tree in parallel, stopping if a solution is found. -}
simpleMainForExploreTreeUntilFirst ::
    (Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration Identity IO (FirstMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome Checkpoint (Maybe (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    Tree result {-^ the tree to explore -} →
    result_monad ()
simpleMainForExploreTreeUntilFirst = dispatchToMainFunction mainForExploreTreeUntilFirst
{-# INLINE simpleMainForExploreTreeUntilFirst #-}

{-| Explore the given tree in parallel in IO, stopping if a solution is found. -}
simpleMainForExploreTreeIOUntilFirst ::
    (Serialize result, MonadIO result_monad) ⇒
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration IO IO (FirstMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome Checkpoint (Maybe (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeIO result {-^ the tree to explore in IO -} →
    result_monad ()
simpleMainForExploreTreeIOUntilFirst = dispatchToMainFunction mainForExploreTreeIOUntilFirst
{-# INLINE simpleMainForExploreTreeIOUntilFirst #-}

{-| Explore the given impure tree in parallel, stopping if a solution is found. -}
simpleMainForExploreTreeImpureUntilFirst ::
    (Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration m m (FirstMode result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome Checkpoint (Maybe (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeT m result {-^ the impure tree to explore -} →
    result_monad ()
simpleMainForExploreTreeImpureUntilFirst = dispatchToMainFunction . mainForExploreTreeImpureUntilFirst
{-# INLINE simpleMainForExploreTreeImpureUntilFirst #-}

------------------- Stop when sum of results meets condition -------------------

{- $found-simple
For more details, follow this link: "LogicGrowsOnTrees.Parallel.Main#found"
 -}

{- $pull-simple
For more details, follow this link: "LogicGrowsOnTrees.Parallel.Main#pull"
 -}

{-| Explore the given pure tree in parallel until the sum of results meets the
    given condition.
 -}
simpleMainForExploreTreeUntilFoundUsingPull ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration Identity IO (FoundModeUsingPull result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    Tree result {-^ the tree to explore -} →
    result_monad ()
simpleMainForExploreTreeUntilFoundUsingPull = dispatchToMainFunction . mainForExploreTreeUntilFoundUsingPull . const
{-# INLINE simpleMainForExploreTreeUntilFoundUsingPull #-}

{-| Explore the given IO tree in parallel until the sum of results meets the
    given condition.
 -}
simpleMainForExploreTreeIOUntilFoundUsingPull ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration IO IO (FoundModeUsingPull result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeIO result {-^ the tree to explore in IO -} →
    result_monad ()
simpleMainForExploreTreeIOUntilFoundUsingPull = dispatchToMainFunction . mainForExploreTreeIOUntilFoundUsingPull . const
{-# INLINE simpleMainForExploreTreeIOUntilFoundUsingPull #-}

{-| Explore the given impure tree in parallel until the sum of results meets the
    given condition.
 -}
simpleMainForExploreTreeImpureUntilFoundUsingPull ::
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration m m (FoundModeUsingPull result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeT m result {-^ the impure tree to explore -} →
    result_monad ()
simpleMainForExploreTreeImpureUntilFoundUsingPull = (dispatchToMainFunction .* mainForExploreTreeImpureUntilFoundUsingPull) . const
{-# INLINE simpleMainForExploreTreeImpureUntilFoundUsingPull #-}

{- $push-simple
For more details, follow this link: "LogicGrowsOnTrees.Parallel.Main#push"
 -}

{-| Explore the given pure tree in parallel until the sum of results meets the
    given condition.
 -}
simpleMainForExploreTreeUntilFoundUsingPush ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration Identity IO (FoundModeUsingPush result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →

    Tree result {-^ the tree to explore -} →
    result_monad ()
simpleMainForExploreTreeUntilFoundUsingPush = dispatchToMainFunction . mainForExploreTreeUntilFoundUsingPush . const
{-# INLINE simpleMainForExploreTreeUntilFoundUsingPush #-}

{-| Explore the given IO tree in parallel until the sum of results meets the
    given condition.
 -}
simpleMainForExploreTreeIOUntilFoundUsingPush ::
    (Monoid result, Serialize result, MonadIO result_monad) ⇒
    (result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration IO IO (FoundModeUsingPush result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeIO result {-^ the tree to explore in IO -} →
    result_monad ()
simpleMainForExploreTreeIOUntilFoundUsingPush = dispatchToMainFunction . mainForExploreTreeIOUntilFoundUsingPush . const
{-# INLINE simpleMainForExploreTreeIOUntilFoundUsingPush #-}

{-| Explore the given impure tree in parallel until the sum of results meets the
    given condition.
 -}
simpleMainForExploreTreeImpureUntilFoundUsingPush ::
    (Monoid result, Serialize result, MonadIO result_monad, Functor m, MonadIO m) ⇒
    (result → Bool) {-^ a condition function that signals when we have found all of the result that we wanted -} →
    (∀ β. m β → IO β) {-^ a function that runs an @m@ action in the 'IO' monad -} →
    Driver result_monad (SharedConfiguration ()) SupervisorConfiguration m m (FoundModeUsingPush result) {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    (RunOutcome (Progress result) (Either result (Progress result)) → IO ())
        {-^ a callback that will be invoked with the outcome of the run; note
            that if the run was 'Completed' then the checkpoint file will be
            deleted if this function finishes successfully
         -} →
    TreeT m result {-^ the impure tree to explore -} →
    result_monad ()
simpleMainForExploreTreeImpureUntilFoundUsingPush = (dispatchToMainFunction .* mainForExploreTreeImpureUntilFoundUsingPush) . const
{-# INLINE simpleMainForExploreTreeImpureUntilFoundUsingPush #-}

--------------------------------------------------------------------------------
---------------------------- Generic main function -----------------------------
--------------------------------------------------------------------------------

{-| This is just like the previous functions, except that it is generalized over
    all tree purities and exploration modes.  (In fact, the specialized
    functions are just wrappers around this function.)
 -}
genericMain ::
    ( MonadIO result_monad
    , ResultFor exploration_mode ~ result
    , Serialize (ProgressFor exploration_mode)
    ) ⇒
    (tree_configuration → ExplorationMode exploration_mode)
        {-^ a function that constructs the exploration mode given the tree
            configuration; note that the constructor that this function returns
            is restricted by the value of the exploration_mode type variable
         -} →
    Purity m n {-^ the purity of the tree -} →
    Driver
        result_monad
        (SharedConfiguration tree_configuration)
        SupervisorConfiguration
        m n
        exploration_mode
        {-^ the driver for the desired adapter (note that all drivers can be specialized to this type) -} →
    Term tree_configuration {-^ a term with any configuration information needed to construct the tree -} →
    TermInfo
        {-^ information about the program; should look something like the following:

                > defTI { termDoc = "count the number of n-queens solutions for a given board size" }
         -} →
    (tree_configuration → RunOutcomeFor exploration_mode → IO ())
        {-^ a callback that will be invoked with the outcome of the run and the
            tree configuration information; note that if the run was 'Completed'
            then the checkpoint file will be deleted if this function finishes
            successfully
         -} →
    (tree_configuration → TreeT m result) {-^ the function that constructs the tree given the tree configuration information -} →
    result_monad ()
genericMain constructExplorationMode_ purity (Driver run) tree_configuration_term program_info_ notifyTerminated_user constructTree_ = do
    tracker_ref ← liftIO . newIORef $ error "tracker was not set"
    let constructController = constructController_ tracker_ref
        notifyTerminated = notifyTerminated_main tracker_ref
        getStartingProgress = getStartingProgress_ tracker_ref
    run DriverParameters{..}
  where
    constructExplorationMode = constructExplorationMode_ . tree_configuration
    shared_configuration_term = makeSharedConfigurationTerm tree_configuration_term
    supervisor_configuration_term =
        SupervisorConfiguration
            <$> checkpoint_configuration_term
            <*> maybe_workload_buffer_size_configuration_term
            <*> statistics_configuration_term
            <*> show_cpu_time_term
    program_info = program_info_
        { man = man program_info_
                ++
                [S "Log Formatting"
                ,P "The following are the variables you can use in the format string:"
                ,I "$msg" "The actual log message"
                ,I "$loggername" "The name of the logger"
                ,I "$prio" "The priority level of the message"
                ,I "$tid" "The thread ID"
                ,I "$pid" "Process ID (Not available on windows)"
                ,I "$time" "The current time"
                ,I "$utcTime" "The current time in UTC Time"
                ]
                ++
                [S "Statistics",P "Each statistic has a long-form name and an abbreviated name (in parentheses) shown below; you may use either when specifying it"]
                ++
                map (I <$> (printf "%s (%s)" <$> statisticLongName <*> statisticShortName) <*> statisticDescription) statistics
        }
    initializeGlobalState SharedConfiguration{logging_configuration=LoggingConfiguration{..}} = do
        case maybe_log_format of
            Nothing → return ()
            Just log_format → do
                handler ← flip setFormatter (simpleLogFormatter log_format) <$> streamHandler stdout log_level
                updateGlobalLogger rootLoggerName $ setHandlers [handler]
        updateGlobalLogger rootLoggerName (setLevel log_level)
    constructTree = constructTree_ . tree_configuration
    getStartingProgress_ tracker_ref shared_configuration SupervisorConfiguration{..} =
        case maybe_checkpoint_configuration of
            Nothing → do
                infoM "Checkpointing is NOT enabled"
                newCPUTimeTracker 0 >>= writeIORef tracker_ref
                return initial_progress
            Just CheckpointConfiguration{..} → do
                infoM $ "Checkpointing enabled"
                infoM $ "Checkpoint file is " ++ checkpoint_path
                infoM $ "Checkpoint interval is " ++ show checkpoint_interval ++ " seconds"
                ifM (doesFileExist checkpoint_path)
                    (do infoM "Loading existing checkpoint file"
                        ProgressAndCPUTime progress initial_cpu_time ← either error id . decodeLazy <$> readFile checkpoint_path
                        newCPUTimeTracker (realToFrac initial_cpu_time) >>= writeIORef tracker_ref
                        return progress
                    )
                    (newCPUTimeTracker 0 >>= writeIORef tracker_ref >> return initial_progress)
      where
        initial_progress = initialProgress . constructExplorationMode $ shared_configuration
    notifyTerminated_main tracker_ref SharedConfiguration{..} SupervisorConfiguration{..} run_outcome@RunOutcome{..} = do
        cpu_time ← readIORef tracker_ref >>= getCurrentCPUTime
        case maybe_checkpoint_configuration of
            Nothing → doEndOfRun cpu_time
            Just CheckpointConfiguration{checkpoint_path} →
                do doEndOfRun cpu_time
                   infoM "Deleting any remaining checkpoint file"
                   removeFileIfExists checkpoint_path
                `finally`
                do 
                   case runTerminationReason of
                    Aborted checkpoint → writeCheckpointFile checkpoint_path checkpoint cpu_time
                    Failure checkpoint _ → writeCheckpointFile checkpoint_path checkpoint cpu_time
                    _ → return ()
      where
        StatisticsConfiguration{..} = statistics_configuration
        doEndOfRun cpu_time = do
            if log_end_stats_configuration
                then writeStatisticsToLog
                        log_stats_level_configuration
                        pastTense
                        runStatistics
                        end_stats_configuration
                else mapM_ (hPutStrLn stderr)
                        .
                        map snd
                        .
                        generateStatistics pastTense runStatistics
                        $
                        end_stats_configuration
            when show_cpu_time . hPutStrLn stderr $
                "Total CPU time used was " ++ showWithUnitPrefix cpu_time ++ "seconds."
            hFlush stderr
            notifyTerminated_user tree_configuration run_outcome
    constructController_ = const . controllerLoop
{-# INLINE genericMain #-}

--------------------------------------------------------------------------------
------------------------------ Utility functions -------------------------------
--------------------------------------------------------------------------------

{-| Converts a 'SupervisorOutcome' to a 'RunOutcome'. -}
extractRunOutcomeFromSupervisorOutcome ::
    Show worker_id ⇒
    SupervisorOutcome fv ip worker_id →
    RunOutcome ip fv
extractRunOutcomeFromSupervisorOutcome SupervisorOutcome{..} = RunOutcome{..}
  where
    runTerminationReason =
        case supervisorTerminationReason of
            SupervisorAborted remaining_progress → Aborted remaining_progress
            SupervisorCompleted result → Completed result
            SupervisorFailure remainig_progress worker_id message →
                Failure remainig_progress $ "Worker " ++ show worker_id ++ " failed with message: " ++ message
    runStatistics = supervisorRunStatistics

{-| Parse the command line options using the given term and term info (the
    latter of which has the program name added to it);  if successful return the
    result, otherwise throw an exception.
 -}
mainParser :: Term α → TermInfo → IO α
mainParser term term_info =
    (if null (termName term_info)
        then getProgName >>= \progname → return $ term_info {termName = progname}
        else return term_info
    ) >>= exec . (term,)

--------------------------------------------------------------------------------
----------------------------------- Internal -----------------------------------
--------------------------------------------------------------------------------

---------------------------------- Statistics ----------------------------------

statistics :: [Statistic]
statistics =
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    [Statistic "walltimes" "times"
        "the starting, ending, and duration (wall) time of the run"
     (\tense RunStatistics{..} →
        let total_time = realToFrac runWallTime :: Float
        in tense
          (printf "The run started at %s, and so far it has run for %sseconds."
            (show runStartTime)
            (showWithUnitPrefix total_time)
          )
          (printf "The run started at %s, ended at %s, and took %sseconds."
            (show runStartTime)
            (show runEndTime)
            (showWithUnitPrefix total_time)
          )
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "supervisor-occupation" "supocc"
        "the percentage of the time that the supervisor was occupied"
     (\tense RunStatistics{..} →
        printf "The supervior %s occupied for %.2f%% of the time so far, of which %.2f%% %s spent inside the SupervisorMonad."
          (tense "has been" "was")
          (runSupervisorOccupation*100)
          (runSupervisorOccupation/runSupervisorMonadOccupation*100)
          (tense "has been" "was")
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "supervisor-calls" "supcalls"
        "the number of calls made to functions in the Supervisor module as well as the average time per call"
     (\tense RunStatistics{..} →
        printf "There %s %i calls made to functions in the Supervisor module, each of which took an average of %sseconds to complete."
          (tense "have been" "were")
          runNumberOfCalls
          (showWithUnitPrefix runAverageTimePerCall)
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "worker-occupation" "workocc"
        "the average percentage of the time that the workers were occupied"
     (\tense RunStatistics{..} →
        printf "Workers %s occupied for %.2f%% of the time on average."
          (tense "have been" "were")
          (runWorkerOccupation*100)
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "worker-waiting-times" "workwait"
        "statistics about the amount of time that it took for a worker to obtain a new workload after finishing a workload"
     (\tense RunStatistics{..} →
        let FunctionOfTimeStatistics{..} = runWorkerWaitTimes
            total_time = realToFrac runWallTime :: Float
        in if timeCount == 0
          then
            printf "At no point %s a worker receive%s a new workload after finishing its current workload."
              (tense "has" "did")
              (tense "d" "")
          else
            if timeMax == 0
              then
                printf "Workers %scompleted their workload and obtained a new one %i times and never once has any had to wait to receive a new workload."
                  (tense "have " "")
                  timeCount
              else
                printf (
                  intercalate ","
                    ["Workers %scompleted their task and obtained a new workload %i times with an average of one every %sseconds or %.1g enqueues/second."
                    ,"The minimum waiting time %s %sseconds, and the maximum waiting time %s %sseconds."
                    ,"On average, a worker %shad to wait %sseconds +/- %sseconds (std. dev) for a new workload."
                    ]
                )
                  (tense "have " "")
                  timeCount
                  (showWithUnitPrefix $ total_time / fromIntegral timeCount)
                  (fromIntegral timeCount / total_time)
                  (tense "has been" "was")
                  (showWithUnitPrefix timeMin)
                  (tense "has been" "was")
                  (tense "has " "")
                  (showWithUnitPrefix timeMax)
                  (showWithUnitPrefix timeAverage)
                  (showWithUnitPrefix timeStdDev)
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "steal-waiting-times" "stealwait"
        "statistics about the amount of time needed to steal a workload"
     (\tense RunStatistics{..} →
        let IndependentMeasurementsStatistics{..} = runStealWaitTimes
            total_time = realToFrac runWallTime :: Float
        in if statCount == 0
          then
            printf "No workloads %s stolen."
                (tense "have been" "were")
          else
            printf (
              intercalate ","
                ["Workloads %s stolen %i times with an average of %sseconds between each steal or %.1g steals/second."
                ,"The minimum waiting time for a steal %s %sseconds, and the maximum waiting time hasbeen %sseconds."
                ,"On average, it %s %sseconds +/- %sseconds (std. dev) to steal a workload."
                ]
            )
              (tense "have been" "were")
              statCount
              (showWithUnitPrefix $ total_time / fromIntegral statCount)
              (fromIntegral statCount / total_time)
              (tense "has been" "was")
              (showWithUnitPrefix statMin)
              (showWithUnitPrefix statMax)
              (tense "has taken" "took")
              (showWithUnitPrefix statAverage)
              (showWithUnitPrefix statStdDev)
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "waiting-worker-count" "waitworkcnt"
        "statistics about the number of waiting workers"
     (\tense RunStatistics{..} →
        let FunctionOfTimeStatistics{..} = runWaitingWorkerStatistics
        in if timeMax == 0
          then
            printf "No worker %s to wait for a workload to become available."
              (tense "has had" "ever had")
          else if timeMin == 0
            then
              printf "On average, %.1f +/ - %.1f (std. dev) workers %s waiting for a workload at any given time;  never more than %i."
                timeAverage
                timeStdDev
                (tense "have been" "were")
                timeMax
            else
              printf "On average, %.1f +/ - %.1f (std. dev) workers %s waiting for a workload at any given time;  never more than %i nor fewer than %i."
                timeAverage
                timeStdDev
                (tense "have been" "were")
                timeMax
                timeMin
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "available-workload-count" "avlwldcnt"
        "This option will cause statistics about the number of available workloads to be printed to standard error after the program terminates."
     (\tense RunStatistics{..} →
        let FunctionOfTimeStatistics{..} = runAvailableWorkloadStatistics
        in if timeMax == 0
            then
              printf "No workload %s to wait for an available worker."
                (tense "has had" "ever had")
            else if timeMin == 0
              then
                printf "On average, %.1f +/ - %.1f (std. dev) workloads %s waiting for a worker at any given time;  never more than %i."
                  timeAverage
                  timeStdDev
                  (tense "have been" "were")
                  timeMax
              else
                printf "On average, %.1f +/ - %.1f (std. dev) workloads %s waiting for a worker at any given time;  never more than %i nor fewer than %i."
                  timeAverage
                  timeStdDev
                  (tense "have been" "were")
                  timeMax
                  timeMin
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "instant-workload-request-rate" "instworkreq"
        "statistics about the (roughly) instantaneous rate at which workloads were requested by finished workers  (obtained via exponential smoothing over a time scale of one second)"
     (\tense RunStatistics{..} →
        let FunctionOfTimeStatistics{..} = runInstantaneousWorkloadRequestRateStatistics
        in printf "On average, the instantanenous rate at which workloads %s being requested %s %.1f +/ - %.1f (std. dev) requests per second;  the rate %s below %.1f nor %s above %.1f."
          (tense "are" "were")
          (tense "is" "was")
          timeAverage
          timeStdDev
          (tense "has never fallen" "never fell")
          timeMin
          (tense "risen" "rose")
          timeMax
     )
    -- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ,Statistic "instant-workload-steal-times" "instwldsteal"
        "statistics about the (roughly) instantaneous amount of time that it took to steal a workload (obtained via exponential smoothing over a time scale of one second"
     (\tense RunStatistics{..} →
        let FunctionOfTimeStatistics{..} = runInstantaneousWorkloadStealTimeStatistics
        in printf "On average, the instantaneous time to steal a workload %s %sseconds +/ - %sseconds (std. dev);  this time interval %s below %sseconds nor %s above %sseconds."
          (tense "has been" "was")
          (showWithUnitPrefix timeAverage)
          (showWithUnitPrefix timeStdDev)
          (tense "has never fallen" "never fell")
          (showWithUnitPrefix timeMin)
          (tense "risen" "rose")
          (showWithUnitPrefix timeMax)
     )
    ]

----------------------------- Configuration terms ------------------------------

checkpoint_configuration_term :: Term (Maybe CheckpointConfiguration)
checkpoint_configuration_term =
    maybe (const Nothing) (Just .* CheckpointConfiguration)
        <$> value (flip opt (
            (optInfo ["c","checkpoint-file"])
            {   optName = "FILEPATH"
            ,   optDoc = unwords
                ["This enables periodic checkpointing with the given path"
                ,"specifying the location of the checkpoint file;  if the file"
                ,"already exists then it will be loaded as the initial starting"
                ,"point for the search."
                ]
            }
            ) Nothing)
        <*> value (flip opt (
            (optInfo ["i","checkpoint-interval"])
            {   optName = "SECONDS"
            ,   optDoc = unwords
                ["This specifies the time between checkpoints (in seconds, with"
                ,"a mandatory decimal point required by cmdtheline); it is"
                ,"ignored if checkpoint file has not been specified."
                ]
            }
            ) 60)
logging_configuration_term :: Term LoggingConfiguration
logging_configuration_term =
    LoggingConfiguration
    <$> (value . opt WARNING $
         (optInfo ["l","log-level"])
         {   optName = "LEVEL"
         ,   optDoc = "This specifies the upper bound (inclusive) on the importance of the messages that will be logged;  it must be one of (in increasing order of importance): DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, or EMERGENCY."
         }
        )
    <*> (value . opt Nothing $
         (optInfo ["log-format"])
         {   optName = "FORMAT"
         ,   optDoc = "This specifies the format of logged messages; see the Log Formatting section for more details."
         }
        )

show_cpu_time_term :: Term Bool
show_cpu_time_term =
    value . flag $
        (optInfo ["show-cpu-time"])
        {   optDoc = "Print the total CPU time when the run finishes."
        }

statistics_configuration_term :: Term StatisticsConfiguration
statistics_configuration_term =
    StatisticsConfiguration
    <$> (value . optAll [] $
         (optInfo ["s","end-stats"])
         {   optName = "STATS"
         ,   optDoc = "A comma-separated list of statistics to be printed to stderr at the end of the run;  you may alternatively specify multiple statistics by using this option multiple times. (See the Statistics section for more information.)"
         }
        )
    <*> (value . flag $
         (optInfo ["log-end-stats"])
         {   optDoc = "If present, then the end-of-run stats are sent to the log instead of stderr."
         }
        )
    <*> (value . optAll [] $
         (optInfo ["log-stats"])
         {   optName = "STATS"
         ,   optDoc = "A comma-separated list of statistics to be regularly logged during the run level;  you may alternatively specify multiple statistics by using this option multiple times. (See the Statistics section for more information.)"
         }
        )
    <*> (value . opt NOTICE $
         (optInfo ["log-stats-level"])
         {   optName = "STATS"
         ,   optDoc = "The level at which to log the stats."
         }
        )
    <*> (value . opt 60 $
         (optInfo ["log-stats-interval"])
         {   optName = "SECONDS"
         ,   optDoc = "The time between logging statistics (in seconds, decimals allowed); it is ignored if no statistics have been enabled for logging."
         }
        )

maybe_workload_buffer_size_configuration_term :: Term (Maybe Int)
maybe_workload_buffer_size_configuration_term =
    value (opt Nothing ((optInfo ["buffer-size"])
        { optName = "SIZE"
        , optDoc = unwords
            ["This option sets the size of the workload buffer which contains"
            ,"stolen workloads that are held at the supervisor so that if a"
            ,"worker needs a new workload it can be given one immediately rather"
            ,"than having to wait for a new workload to be stolen. This setting"
            ,"should be large enough that a request for a new workload can"
            ,"always be answered immediately using a workload from the buffer,"
            ,"which is roughly a function of the product of the number of"
            ,"workloads requested per second and the time needed to steal a new"
            ,"workload (both of which are server statistics than you can request"
            ,"to see upon completions). If you are not having problems with"
            ,"scaling, then you can ignore this option (it defaults to 4)."
            ]
        }
    ))

makeSharedConfigurationTerm :: Term tree_configuration → Term (SharedConfiguration tree_configuration)
makeSharedConfigurationTerm tree_configuration_term =
    SharedConfiguration
        <$> logging_configuration_term
        <*> tree_configuration_term

------------------------------------ Loops -------------------------------------

checkpointLoop ::
    ( RequestQueueMonad m
    , Serialize (ProgressFor (ExplorationModeFor m))
    ) ⇒ CPUTimeTracker → CheckpointConfiguration → m α
checkpointLoop tracker CheckpointConfiguration{..} = go False
  where
    delay = round $ checkpoint_interval * 1000000

    go alerted_since_last_failure = do
        new_alerted_since_last_failure ←
            (do join $
                    liftM2 (liftIO .* writeCheckpointFile checkpoint_path)
                        requestProgressUpdate
                        (liftIO (getCurrentCPUTime tracker))
                infoM $ "Checkpoint written to " ++ show checkpoint_path
                when alerted_since_last_failure $
                    noticeM "The problem with the checkpoint has been resolved."
                return False
            ) `catch` (\(e::SomeException) → do
                (if alerted_since_last_failure then infoM else errorM) $
                    "Failed writing checkpoint to \"" ++ checkpoint_path ++ "\" with error \"" ++ show e ++ "\";  will keep retrying in case the problem gets resolved."
                return True
            )
        liftIO $ threadDelay delay
        go new_alerted_since_last_failure

statisticsLoop :: RequestQueueMonad m ⇒ [[Statistic]] → Priority → Float → m α
statisticsLoop stats level interval = forever $ do
    liftIO $ threadDelay delay
    run_statistics ← getCurrentStatistics
    liftIO $
        writeStatisticsToLog
            level
            pastPerfectTense
            run_statistics
            stats
  where
    delay = round $ interval * 1000000

controllerLoop ::
    ( RequestQueueMonad m
    , Serialize (ProgressFor (ExplorationModeFor m))
    ) ⇒ IORef CPUTimeTracker → SupervisorConfiguration → m ()
controllerLoop tracker_ref SupervisorConfiguration{statistics_configuration=StatisticsConfiguration{..},..} = do
    tracker ← liftIO . readIORef $ tracker_ref 
    startCPUTimeTracker tracker
    maybe (return ()) setWorkloadBufferSize maybe_workload_buffer_size_configuration
    maybe (return ()) (void . fork . checkpointLoop tracker) maybe_checkpoint_configuration
    when (not . null $ log_stats_configuration) $
        void . fork $ statisticsLoop log_stats_configuration log_stats_level_configuration log_stats_interval_configuration

-------------------------------- Miscellaneous ---------------------------------

default_terminfo :: TermInfo
default_terminfo = defTI { termDoc = "LogicGrowsOnTrees program" }

dispatchToMainFunction f driver notifyTerminated tree =
    f   driver
        (pure ())
        default_terminfo
        (const notifyTerminated)
        (const tree)
{-# INLINE dispatchToMainFunction #-}

generateStatistics :: Tense → RunStatistics → [[Statistic]] → [(String,String)]
generateStatistics tense run_statistics =
    map (
        statisticLongName
        &&&
        (\(statisticApplication → apply) → apply tense run_statistics)
    )
    .
    nub
    .
    concat

pastPerfectTense, pastTense :: Tense
pastPerfectTense x _ = x
pastTense _ x = x

removeFileIfExists :: FilePath → IO ()
removeFileIfExists path =
    handleJust
        (\e → if isDoesNotExistError e then Just () else Nothing)
        (\_ → return ())
        (removeFile path)

showWithUnitPrefix :: Real n ⇒ n → String
showWithUnitPrefix 0 = "0 "
showWithUnitPrefix x = printf "%.1f %s" x_scaled (unitName unit)
  where
    (x_scaled :: Float,Just unit) = formatValue (Left FormatSiAll) . realToFrac $ x

writeStatisticsToLog :: Priority → Tense → RunStatistics → [[Statistic]] → IO ()
writeStatisticsToLog level =
    (\outputs →
        unless (null outputs) $ do
            logIt "=== BEGIN STATISTICS ==="
            forM_ outputs $ \(name,output) → logIt (name ++ ": " ++ output)
            logIt "=== END STATISTICS ==="
    )
    .**
    generateStatistics
  where
    logIt = logM "LogicGrowsOnTrees.Parallel.Main" level

writeCheckpointFile :: (Serialize ip, MonadIO m) ⇒ FilePath → ip → NominalDiffTime → m ()
writeCheckpointFile checkpoint_path checkpoint cpu_time = do
    infoM $ "Writing checkpoint file"
    liftIO $
        (do writeFile checkpoint_temp_path . encodeLazy $ ProgressAndCPUTime checkpoint (toRational cpu_time)
            renameFile checkpoint_temp_path checkpoint_path
        ) `onException` (
            removeFileIfExists checkpoint_temp_path
        )
  where
    checkpoint_temp_path = checkpoint_path ++ ".tmp"
