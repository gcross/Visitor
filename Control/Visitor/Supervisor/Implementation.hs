-- Language extensions {{{
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}
-- }}}

module Control.Visitor.Supervisor.Implementation -- {{{
    ( CountStatistics(..)
    , RunStatistics(..)
    , SupervisorAbortMonad()
    , SupervisorCallbacks(..)
    , SupervisorFullConstraint
    , SupervisorMonadConstraint
    , SupervisorOutcome(..)
    , SupervisorTerminationReason(..)
    , SupervisorWorkerIdConstraint
    , TimeStatistics(..)
    , abortSupervisor
    , abortSupervisorWithReason
    , addWorker
    , changeSupervisorOccupiedStatus
    , getCurrentProgress
    , getCurrentStatistics
    , getNumberOfWorkers
    , liftUserToContext
    , localWithinContext
    , performGlobalProgressUpdate
    , receiveProgressUpdate
    , receiveStolenWorkload
    , receiveWorkerFinishedWithRemovalFlag
    , removeWorker
    , removeWorkerIfPresent
    , runSupervisorStartingFrom
    , setSupervisorDebugMode
    , tryGetWaitingWorker
    ) where -- }}}

-- Imports {{{
import Control.Applicative ((<$>),(<*>),liftA2)
import Control.Arrow ((&&&),first)
import Control.Category ((>>>))
import Control.Exception (AsyncException(ThreadKilled,UserInterrupt),Exception(..),assert,throw)
import Control.Lens ((&))
import Control.Lens.At (at)
import Control.Lens.Getter ((^.),use)
import Control.Lens.Setter ((.~),(+~),(.=),(%=),(+=))
import Control.Lens.Lens ((<%=),(<<%=),(%%=),(<<.=),Lens)
import Control.Lens.TH (makeLenses)
import Control.Monad ((>=>),liftM,liftM2,mplus,unless,when)
import Control.Monad.IO.Class (MonadIO,liftIO)
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Reader (ask,asks)
import Control.Monad.Tools (ifM,whenM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Abort (AbortT(..),abort,runAbortT,unwrapAbortT)
import Control.Monad.Trans.Abort.Instances.MTL
import Control.Monad.Trans.Reader (ReaderT,runReaderT)
import Control.Monad.Trans.State.Strict (StateT,evalState,evalStateT,execState,execStateT,runStateT)

import Data.Derive.Monoid
import Data.DeriveTH
import Data.Either.Unwrap (whenLeft)
import qualified Data.Foldable as Fold
import qualified Data.IntMap as IntMap
import Data.IntMap (IntMap)
import Data.List (inits)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe (fromJust,fromMaybe,isJust,isNothing)
import Data.Monoid ((<>),Monoid(..))
import Data.Monoid.Statistics (StatMonoid(..))
import Data.Monoid.Statistics.Numeric (CalcCount(..),CalcMean(..),CalcVariance(..),Min(..),Max(..),Variance(..),calcStddev)
import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Sequence as Seq
import Data.Typeable (Typeable)
import Data.Time.Clock (NominalDiffTime,UTCTime,diffUTCTime,getCurrentTime)

import qualified System.Log.Logger as Logger
import System.Log.Logger (Priority(DEBUG,INFO))
import System.Log.Logger.TH

import Control.Visitor.Checkpoint
import Control.Visitor.Path
import Control.Visitor.Worker
import Control.Visitor.Workload
-- }}}

-- Logging Functions {{{
deriveLoggers "Logger" [DEBUG,INFO]
-- }}}

-- Exceptions {{{

-- InconsistencyError {{{
data InconsistencyError = -- {{{
    IncompleteWorkspace Checkpoint
  | OutOfSourcesForNewWorkloads
  | SpaceFullyExploredButSearchNotTerminated
  deriving (Eq,Typeable)
-- }}}
instance Show InconsistencyError where -- {{{
    show (IncompleteWorkspace workspace) = "Full workspace is incomplete: " ++ show workspace
    show OutOfSourcesForNewWorkloads = "The search is incomplete but there are no sources of workloads available."
    show SpaceFullyExploredButSearchNotTerminated = "The space has been fully explored but the search was not terminated."
-- }}}
instance Exception InconsistencyError
-- }}}

-- WorkerManagementError {{{
data WorkerManagementError worker_id = -- {{{
    ActiveWorkersRemainedAfterSpaceFullyExplored [worker_id]
  | ConflictingWorkloads (Maybe worker_id) Path (Maybe worker_id) Path
  | SpaceFullyExploredButWorkloadsRemain [(Maybe worker_id,Workload)]
  | WorkerAlreadyKnown String worker_id
  | WorkerAlreadyHasWorkload worker_id
  | WorkerNotKnown String worker_id
  | WorkerNotActive String worker_id
  deriving (Eq,Typeable)
 -- }}}
instance Show worker_id ⇒ Show (WorkerManagementError worker_id) where -- {{{
    show (ActiveWorkersRemainedAfterSpaceFullyExplored worker_ids) = "Worker ids " ++ show worker_ids ++ " were still active after the space was supposedly fully explored."
    show (ConflictingWorkloads wid1 path1 wid2 path2) =
        "Workload " ++ f wid1 ++ " with initial path " ++ show path1 ++ " conflicts with workload " ++ f wid2 ++ " with initial path " ++ show path2 ++ "."
      where
        f Nothing = "sitting idle"
        f (Just wid) = "of worker " ++ show wid
    show (SpaceFullyExploredButWorkloadsRemain workers_and_workloads) = "The space has been fully explored, but the following workloads remain: " ++ show workers_and_workloads
    show (WorkerAlreadyKnown action worker_id) = "Worker id " ++ show worker_id ++ " already known when " ++ action ++ "."
    show (WorkerAlreadyHasWorkload worker_id) = "Attempted to send workload to worker id " ++ show worker_id ++ " which is already active."
    show (WorkerNotKnown action worker_id) = "Worker id " ++ show worker_id ++ " not known when " ++ action ++ "."
    show (WorkerNotActive action worker_id) = "Worker id " ++ show worker_id ++ " not active when " ++ action ++ "."
-- }}}
instance (Eq worker_id, Show worker_id, Typeable worker_id) ⇒ Exception (WorkerManagementError worker_id)
-- }}}

-- SupervisorError {{{
data SupervisorError worker_id = -- {{{
    SupervisorInconsistencyError InconsistencyError
  | SupervisorWorkerManagementError (WorkerManagementError worker_id)
  deriving (Eq,Typeable)
-- }}}
instance Show worker_id ⇒ Show (SupervisorError worker_id) where -- {{{
    show (SupervisorInconsistencyError e) = show e
    show (SupervisorWorkerManagementError e) = show e
-- }}}
instance (Eq worker_id, Show worker_id, Typeable worker_id) ⇒ Exception (SupervisorError worker_id) where -- {{{
    toException (SupervisorInconsistencyError e) = toException e
    toException (SupervisorWorkerManagementError e) = toException e
    fromException e =
        (SupervisorInconsistencyError <$> fromException e)
        `mplus`
        (SupervisorWorkerManagementError <$> fromException e)
-- }}}
-- }}}

-- }}}

-- Types {{{

-- Statistics {{{

data CountStatistics = CountStatistics -- {{{
    {   countAverage :: !Double
    ,   countStdDev :: !Double
    ,   countMin :: !Int
    ,   countMax :: !Int
    } deriving (Eq,Show)
-- }}}

data RetiredOccupationStatistics = RetiredOccupationStatistics -- {{{
    {   _occupied_time :: !NominalDiffTime
    ,   _total_time :: !NominalDiffTime
    } deriving (Eq,Show)
$( makeLenses ''RetiredOccupationStatistics )
-- }}}

data OccupationStatistics = OccupationStatistics -- {{{
    {   _start_time :: !UTCTime
    ,   _last_occupied_change_time :: !UTCTime
    ,   _total_occupied_time :: !NominalDiffTime
    ,   _is_currently_occupied :: !Bool
    } deriving (Eq,Show)
$( makeLenses ''OccupationStatistics )
-- }}}

data RunStatistics = -- {{{
    RunStatistics
    {   runStartTime :: !UTCTime
    ,   runEndTime :: !UTCTime
    ,   runWallTime :: !NominalDiffTime
    ,   runSupervisorOccupation :: !Float
    ,   runWorkerOccupation :: !Float
    ,   runWorkerWaitTimes :: !TimeStatistics
    ,   runWaitingWorkerCountStatistics :: !CountStatistics
    ,   runAvailableWorkloadCountStatistics :: !CountStatistics
    } deriving (Eq,Show)
-- }}}

data TimeStatistics = TimeStatistics -- {{{
    {   timeCount :: {-# UNPACK #-} !Int
    ,   timeMin :: {-# UNPACK #-} !Double
    ,   timeMax :: {-# UNPACK #-} !Double
    ,   timeMean :: {-# UNPACK #-} !Double
    ,   timeStdDev ::  {-# UNPACK #-} !Double
    } deriving (Eq,Show)
-- }}}

data TimeStatisticsMonoid = TimeStatisticsMonoid -- {{{
    {   timeDataMin :: {-# UNPACK #-} !Min
    ,   timeDataMax :: {-# UNPACK #-} !Max
    ,   timeDataVariance ::  {-# UNPACK #-} !Variance
    } deriving (Eq,Show)
$( derive makeMonoid ''TimeStatisticsMonoid )
-- }}}

data TimeWeightedCountStatistics = TimeWeightedCountStatistics -- {{{
    {   _previous_value :: !Int
    ,   _previous_time :: !UTCTime
    ,   _first_moment :: !Double
    ,   _second_moment :: !Double
    ,   _minimum_value :: !Int
    ,   _maximum_value :: !Int
    } deriving (Eq,Show)
$( makeLenses ''TimeWeightedCountStatistics )
-- }}}

-- }}}

data SupervisorCallbacks result worker_id m = -- {{{
    SupervisorCallbacks
    {   broadcastProgressUpdateToWorkers :: [worker_id] → m ()
    ,   broadcastWorkloadStealToWorkers :: [worker_id] → m ()
    ,   receiveCurrentProgress :: Progress result → m ()
    ,   sendWorkloadToWorker :: Workload → worker_id → m ()
    }
-- }}}

type SupervisorMonadState result worker_id = MonadState (SupervisorState result worker_id)

data SupervisorState result worker_id = -- {{{
    SupervisorState
    {   _waiting_workers_or_available_workloads :: !(Either (Map worker_id (Maybe UTCTime)) (Set Workload))
    ,   _known_workers :: !(Set worker_id)
    ,   _active_workers :: !(Map worker_id Workload)
    ,   _current_steal_depth :: !Int
    ,   _available_workers_for_steal :: !(IntMap (Set worker_id))
    ,   _workers_pending_workload_steal :: !(Set worker_id)
    ,   _workers_pending_progress_update :: !(Set worker_id)
    ,   _current_progress :: !(Progress result)
    ,   _debug_mode :: !Bool
    ,   _supervisor_occupation_statistics :: OccupationStatistics
    ,   _worker_occupation_statistics :: !(Map worker_id OccupationStatistics)
    ,   _retired_worker_occupation_statistics :: !(Map worker_id RetiredOccupationStatistics)
    ,   _worker_wait_time_statistics :: !TimeStatisticsMonoid
    ,   _waiting_worker_count_statistics :: !TimeWeightedCountStatistics
    ,   _available_workload_count_statistics :: !TimeWeightedCountStatistics
    }
$( makeLenses ''SupervisorState )
-- }}}

data SupervisorTerminationReason result worker_id = -- {{{
    SupervisorAborted (Progress result)
  | SupervisorCompleted result
  | SupervisorFailure worker_id String
  deriving (Eq,Show)
-- }}}

data SupervisorOutcome result worker_id = -- {{{
    SupervisorOutcome
    {   supervisorTerminationReason :: SupervisorTerminationReason result worker_id
    ,   supervisorRunStatistics :: RunStatistics
    ,   supervisorRemainingWorkers :: [worker_id]
    } deriving (Eq,Show)
-- }}}

type SupervisorContext result worker_id m = -- {{{
    StateT (SupervisorState result worker_id)
        (ReaderT (SupervisorCallbacks result worker_id m) m)
-- }}}

type SupervisorAbortMonad result worker_id m = -- {{{
    AbortT
        (SupervisorOutcome result worker_id)
        (SupervisorContext result worker_id m)
-- }}}

-- }}}

-- Contraints {{{
type SupervisorMonadConstraint m = (Functor m, MonadIO m)
type SupervisorWorkerIdConstraint worker_id = (Eq worker_id, Ord worker_id, Show worker_id, Typeable worker_id)
type SupervisorFullConstraint worker_id m = (SupervisorWorkerIdConstraint worker_id,SupervisorMonadConstraint m)
-- }}}

-- Instances {{{

instance Monoid RetiredOccupationStatistics where -- {{{
    mempty = RetiredOccupationStatistics 0 0
    mappend x y = x & (occupied_time +~ y^.occupied_time) & (total_time +~ y^.total_time)
-- }}}

instance StatMonoid TimeStatisticsMonoid NominalDiffTime where -- {{{
    pappend t =
        TimeStatisticsMonoid
            <$> (pappend t' . timeDataMin)
            <*> (pappend t' . timeDataMax)
            <*> (pappend t' . timeDataVariance)
      where t' = fromRational . toRational $ t :: Double
-- }}}

instance CalcCount TimeStatisticsMonoid where -- {{{
    calcCount = calcCount . timeDataVariance
-- }}}

instance CalcMean TimeStatisticsMonoid where -- {{{
    calcMean = calcMean . timeDataVariance
-- }}}

instance CalcVariance TimeStatisticsMonoid where -- {{{
    calcVariance = calcVariance . timeDataVariance
    calcVarianceUnbiased = calcVarianceUnbiased . timeDataVariance
-- }}}

-- }}}

-- Functions {{{

abortSupervisor :: SupervisorFullConstraint worker_id m ⇒ SupervisorAbortMonad result worker_id m α -- {{{
abortSupervisor = use current_progress >>= abortSupervisorWithReason . SupervisorAborted
-- }}}

abortSupervisorWithReason ::  -- {{{
    SupervisorFullConstraint worker_id m ⇒
    SupervisorTerminationReason result worker_id →
    SupervisorAbortMonad result worker_id m α
abortSupervisorWithReason reason =
    (SupervisorOutcome
        <$> (return reason)
        <*> (lift getCurrentStatistics)
        <*> (Set.toList <$> use known_workers)
    ) >>= abort
-- }}}

addWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
addWorker worker_id = postValidate ("addWorker " ++ show worker_id) $ do
    infoM $ "Adding worker " ++ show worker_id
    validateWorkerNotKnown "adding worker" worker_id
    known_workers %= Set.insert worker_id
    start_time ← liftIO getCurrentTime
    worker_occupation_statistics %= Map.insert worker_id (OccupationStatistics start_time start_time 0 False)
    tryToObtainWorkloadFor True worker_id
-- }}}

beginWorkerOccupied :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
beginWorkerOccupied = changeWorkerOccupiedStatus True
-- }}}

changeOccupiedStatus :: -- {{{
    SupervisorMonadConstraint m ⇒
    Bool →
    OccupationStatistics →
    m OccupationStatistics
changeOccupiedStatus new_occupied_status = execStateT $
    (/= new_occupied_status) <$> use is_currently_occupied
    >>=
    flip when (do
        current_time ← liftIO getCurrentTime
        is_currently_occupied .= new_occupied_status
        last_time ← last_occupied_change_time <<%= const current_time
        unless new_occupied_status $ total_occupied_time += (current_time `diffUTCTime` last_time)
    )
-- }}}

changeSupervisorOccupiedStatus :: SupervisorMonadConstraint m ⇒ Bool → SupervisorContext result worker_id m () -- {{{
changeSupervisorOccupiedStatus new_status =
    use supervisor_occupation_statistics
    >>=
    changeOccupiedStatus new_status
    >>=
    (supervisor_occupation_statistics .=)
-- }}}

changeWorkerOccupiedStatus :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Bool →
    worker_id →
    SupervisorContext result worker_id m ()
changeWorkerOccupiedStatus new_status worker_id =
    use worker_occupation_statistics
    >>=
    changeOccupiedStatus new_status . fromJust . Map.lookup worker_id
    >>=
    (worker_occupation_statistics %=) . Map.insert worker_id
-- }}}

checkWhetherMoreStealsAreNeeded :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorContext result worker_id m ()
checkWhetherMoreStealsAreNeeded = do
    number_of_waiting_workers ← either Map.size (const 0) <$> use waiting_workers_or_available_workloads
    number_of_pending_workload_steals ← Set.size <$> use workers_pending_workload_steal
    available_workers ← use available_workers_for_steal
    when (number_of_pending_workload_steals == 0
       && number_of_waiting_workers > 0
       && IntMap.null available_workers
      ) $ throw OutOfSourcesForNewWorkloads
    let number_of_needed_steals = (number_of_waiting_workers - number_of_pending_workload_steals) `max` 0
    when (number_of_needed_steals > 0 && (not . IntMap.null) available_workers) $ do
        depth ← do
            old_depth ← use current_steal_depth
            if number_of_pending_workload_steals == 0 && IntMap.notMember old_depth available_workers
                then do
                    let new_depth = fst (IntMap.findMin available_workers)
                    current_steal_depth .= new_depth
                    return new_depth
                else return old_depth
        let (maybe_new_workers,workers_to_steal_from) =
                go []
                   (fromMaybe Set.empty . IntMap.lookup depth $ available_workers)
                   number_of_needed_steals
              where
                go accum (Set.minView → Nothing) _ = (Nothing,accum)
                go accum workers 0 = (Just workers,accum)
                go accum (Set.minView → Just (worker_id,rest_workers)) n =
                    go (worker_id:accum) rest_workers (n-1)
        workers_pending_workload_steal %= (Set.union . Set.fromList) workers_to_steal_from
        available_workers_for_steal %= IntMap.update (const maybe_new_workers) depth
        unless (null workers_to_steal_from) $ do
            infoM $ "Sending workload steal requests to " ++ show workers_to_steal_from
            asks broadcastWorkloadStealToWorkers >>= liftUserToContext . ($ workers_to_steal_from)
-- }}}

clearPendingProgressUpdate :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
clearPendingProgressUpdate worker_id =
    Set.member worker_id <$> use workers_pending_progress_update >>= flip when
    -- Note, the conditional above is needed to prevent a "misfire" where
    -- we think that we have just completed a progress update even though
    -- none was started.
    (do workers_pending_progress_update %= Set.delete worker_id
        no_progress_updates_are_pending ← Set.null <$> use workers_pending_progress_update
        when no_progress_updates_are_pending sendCurrentProgressToUser
    )
-- }}}

deactivateWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Bool →
    worker_id →
    SupervisorContext result worker_id m ()
deactivateWorker reenqueue_workload worker_id = do
    workers_pending_workload_steal %= Set.delete worker_id
    dequeueWorkerForSteal worker_id
    if reenqueue_workload
        then active_workers <<%= Map.delete worker_id
              >>=
                enqueueWorkload
                .
                fromMaybe (error $ "Attempt to deactivate worker " ++ show worker_id ++ " which was not listed as active.")
                .
                Map.lookup worker_id
        else active_workers %= Map.delete worker_id
    clearPendingProgressUpdate worker_id
    checkWhetherMoreStealsAreNeeded
-- }}}

dequeueWorkerForSteal :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
dequeueWorkerForSteal worker_id =
    getWorkerDepth worker_id >>= \depth →
        available_workers_for_steal %=
            IntMap.update
                (\queue → let new_queue = Set.delete worker_id queue
                          in if Set.null new_queue then Nothing else Just new_queue
                )
                depth
-- }}}

endSupervisorOccupied :: SupervisorMonadConstraint m ⇒ SupervisorContext result worker_id m () -- {{{
endSupervisorOccupied = changeSupervisorOccupiedStatus False
-- }}}

endWorkerOccupied :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
endWorkerOccupied = changeWorkerOccupiedStatus False
-- }}}

enqueueWorkerForSteal :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
enqueueWorkerForSteal worker_id =
    getWorkerDepth worker_id >>= \depth →
        available_workers_for_steal %=
            IntMap.alter
                (Just . maybe (Set.singleton worker_id) (Set.insert worker_id))
                depth
-- }}}

enqueueWorkload :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Workload →
    SupervisorContext result worker_id m ()
enqueueWorkload workload =
    use waiting_workers_or_available_workloads
    >>=
    \x → case x of
        Left (Map.minViewWithKey → Just ((free_worker_id,maybe_time_started_waiting),remaining_workers)) → do
            waiting_workers_or_available_workloads .= Left remaining_workers
            maybe (return ())
                  (timePassedSince >=> (worker_wait_time_statistics %=) . pappend)
                  maybe_time_started_waiting
            sendWorkloadTo workload free_worker_id
            updateTimeWeightedCountStatisticsUsingLens waiting_worker_count_statistics (Map.size remaining_workers)
        Left (Map.minViewWithKey → Nothing) → do
            waiting_workers_or_available_workloads .= Right (Set.singleton workload)
            updateTimeWeightedCountStatisticsUsingLens available_workload_count_statistics 1
        Right available_workloads → do
            waiting_workers_or_available_workloads .= Right (Set.insert workload available_workloads)
            updateTimeWeightedCountStatisticsUsingLens available_workload_count_statistics (Set.size available_workloads + 1)
-- }}}

extractTimeStatistics :: TimeStatisticsMonoid → TimeStatistics -- {{{
extractTimeStatistics =
    TimeStatistics
        <$>  calcCount
        <*> (calcMin . timeDataMin)
        <*> (calcMax . timeDataMax)
        <*>  calcMean
        <*>  calcStddev
-- }}}

finalizeCountStatistics :: SupervisorMonadConstraint m ⇒ UTCTime → m Int → m TimeWeightedCountStatistics → m CountStatistics -- {{{ 
finalizeCountStatistics start_time getFinalValue getWeightedStatistics = do
    end_time ← liftIO getCurrentTime
    let total_weight = fromRational . toRational $ (end_time `diffUTCTime` start_time)
    final_value ← getFinalValue
    evalState (do
        countAverage ← (/total_weight) <$> use first_moment
        countStdDev ← sqrt . (\x → x-countAverage*countAverage) . (/total_weight) <$> use second_moment
        countMin ← min final_value <$> use minimum_value
        countMax ← max final_value <$> use maximum_value
        return $ CountStatistics{..}
     ) . updateTimeWeightedCountStatistics end_time final_value <$> getWeightedStatistics
-- }}}

getCurrentProgress :: SupervisorMonadConstraint m ⇒ SupervisorContext result worker_id m (Progress result) -- {{{
getCurrentProgress = use current_progress
-- }}}

getCurrentStatistics :: SupervisorFullConstraint worker_id m ⇒ SupervisorContext result worker_id m RunStatistics -- {{{
getCurrentStatistics = do
    runEndTime ← liftIO getCurrentTime
    runStartTime ← use (supervisor_occupation_statistics . start_time)
    let runWallTime = runEndTime `diffUTCTime` runStartTime
    runSupervisorOccupation ←
        use supervisor_occupation_statistics
        >>=
        retireOccupationStatistics
        >>=
        return . getOccupationFraction
    runWorkerOccupation ←
        getOccupationFraction . mconcat . Map.elems
        <$>
        liftM2 (Map.unionWith (<>))
            (use retired_worker_occupation_statistics)
            (use worker_occupation_statistics >>= retireManyOccupationStatistics)
    runWorkerWaitTimes ← extractTimeStatistics <$> use worker_wait_time_statistics
    runWaitingWorkerCountStatistics ←
        finalizeCountStatistics
            runStartTime
            (either Map.size (const 0) <$> use waiting_workers_or_available_workloads)
            (use waiting_worker_count_statistics)
    runAvailableWorkloadCountStatistics ←
        finalizeCountStatistics
            runStartTime
            (either (const 0) Set.size <$> use waiting_workers_or_available_workloads)
            (use available_workload_count_statistics)
    return RunStatistics{..}
-- }}}

getNumberOfWorkers :: SupervisorMonadConstraint m ⇒ SupervisorContext result worker_id m Int -- {{{
getNumberOfWorkers = liftM Set.size . use $ known_workers
-- }}}

getOccupationFraction :: RetiredOccupationStatistics → Float -- {{{
getOccupationFraction = fromRational . toRational . liftA2 (/) (^.occupied_time) (^.total_time)
-- }}}

getWorkerDepth :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m Int
getWorkerDepth worker_id =
    maybe
        (error $ "Attempted to use the depth of inactive worker " ++ show worker_id ++ ".")
        workloadDepth
    .
    Map.lookup worker_id
    <$>
    use active_workers
-- }}}

initialTimeWeightedCountStatisticsForStartingTime :: UTCTime → TimeWeightedCountStatistics -- {{{
initialTimeWeightedCountStatisticsForStartingTime starting_time =
    TimeWeightedCountStatistics
        0
        starting_time
        0
        0
        maxBound
        minBound
-- }}}

liftUserToContext :: Monad m ⇒ m α → SupervisorContext result worker_id m α -- {{{
liftUserToContext = lift . lift
-- }}}

localWithinContext :: -- {{{
    MonadReader r m ⇒
    (r → r) →
    SupervisorAbortMonad result worker_id m α →
    SupervisorAbortMonad result worker_id m α
localWithinContext f m = do
    actions ← ask
    old_state ← get
    (result,new_state) ←
        lift
        .
        lift
        .
        lift
        .
        local f
        .
        flip runReaderT actions
        .
        flip runStateT old_state
        .
        unwrapAbortT
        $
        m
    put new_state
    either abort return result
-- }}}

performGlobalProgressUpdate :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorContext result worker_id m ()
performGlobalProgressUpdate = postValidate "performGlobalProgressUpdate" $ do
    infoM $ "Performing global progress update."
    active_worker_ids ← Map.keysSet <$> use active_workers
    if (Set.null active_worker_ids)
        then sendCurrentProgressToUser
        else do
            workers_pending_progress_update .= active_worker_ids
            asks broadcastProgressUpdateToWorkers >>= liftUserToContext . ($ Set.toList active_worker_ids)
-- }}}

postValidate :: -- {{{
    (SupervisorMonadState result worker_id m, SupervisorFullConstraint worker_id m) ⇒
    String →
    m α →
    m α
postValidate label action = action >>= \result →
  (whenDebugging $ do
    debugM $ " === BEGIN VALIDATE === " ++ label
    use known_workers >>= debugM . ("Known workers is now " ++) . show
    use active_workers >>= debugM . ("Active workers is now " ++) . show
    use waiting_workers_or_available_workloads >>= debugM . ("Waiting/Available queue is now " ++) . show
    use current_progress >>= debugM . ("Current checkpoint is now " ++) . show . progressCheckpoint
    workers_and_workloads ←
        liftM2 (++)
            (map (Nothing,) . Set.toList . either (const (Set.empty)) id <$> use waiting_workers_or_available_workloads)
            (map (first Just) . Map.assocs <$> use active_workers)
    let go [] _ = return ()
        go ((maybe_worker_id,Workload initial_path _):rest_workloads) known_prefixes =
            case Map.lookup initial_path_as_list known_prefixes of
                Nothing → go rest_workloads . mappend known_prefixes . Map.fromList . map (,(maybe_worker_id,initial_path)) . inits $ initial_path_as_list
                Just (maybe_other_worker_id,other_initial_path) →
                    throw $ ConflictingWorkloads maybe_worker_id initial_path maybe_other_worker_id other_initial_path
          where initial_path_as_list = Fold.toList initial_path
    go workers_and_workloads Map.empty
    Progress checkpoint _ ← use current_progress
    let total_workspace =
            mappend checkpoint
            .
            mconcat
            .
            map (flip checkpointFromInitialPath Explored . workloadPath . snd)
            $
            workers_and_workloads
    unless (total_workspace == Explored) $ throw $ IncompleteWorkspace total_workspace
    Progress checkpoint _ ← use current_progress
    when (checkpoint == Explored) $
        if null workers_and_workloads
            then throw $ SpaceFullyExploredButSearchNotTerminated
            else throw $ SpaceFullyExploredButWorkloadsRemain workers_and_workloads
    debugM $ " === END VALIDATE === " ++ label
  ) >> return result
-- }}}

receiveProgressUpdate :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    ProgressUpdate result →
    SupervisorContext result worker_id m ()
receiveProgressUpdate worker_id (ProgressUpdate progress_update remaining_workload) = postValidate ("receiveProgressUpdate " ++ show worker_id ++ " ...") $ do
    infoM $ "Received progress update from " ++ show worker_id
    validateWorkerKnownAndActive "receiving progress update" worker_id
    current_progress %= (`mappend` progress_update)
    is_pending_workload_steal ← Set.member worker_id <$> use workers_pending_workload_steal
    unless is_pending_workload_steal $ dequeueWorkerForSteal worker_id
    active_workers %= Map.insert worker_id remaining_workload
    unless is_pending_workload_steal $ enqueueWorkerForSteal worker_id
    clearPendingProgressUpdate worker_id
-- }}}

receiveStolenWorkload :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    Maybe (StolenWorkload result) →
    SupervisorContext result worker_id m ()
receiveStolenWorkload worker_id maybe_stolen_workload = postValidate ("receiveStolenWorkload " ++ show worker_id ++ " ...") $ do
    infoM $ "Received stolen workload from " ++ show worker_id
    validateWorkerKnownAndActive "receiving stolen workload" worker_id
    workers_pending_workload_steal %= Set.delete worker_id
    case maybe_stolen_workload of
        Nothing → return ()
        Just (StolenWorkload (ProgressUpdate progress_update remaining_workload) workload) → do
            current_progress %= (`mappend` progress_update)
            active_workers %= Map.insert worker_id remaining_workload
            enqueueWorkload workload
    enqueueWorkerForSteal worker_id
    checkWhetherMoreStealsAreNeeded
-- }}}

receiveWorkerFinishedWithRemovalFlag :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Bool →
    worker_id →
    Progress result →
    SupervisorAbortMonad result worker_id m ()
receiveWorkerFinishedWithRemovalFlag remove_worker worker_id final_progress = postValidate ("receiveWorkerFinished " ++ show worker_id ++ " " ++ show (progressCheckpoint final_progress)) $ do
    infoM $ if remove_worker
        then "Worker " ++ show worker_id ++ " finished and removed."
        else "Worker " ++ show worker_id ++ " finished."
    lift $ validateWorkerKnownAndActive "the worker was declared finished" worker_id
    Progress checkpoint new_results ← current_progress <%= (<> final_progress)
    when remove_worker . lift $ retireWorker worker_id
    case checkpoint of
        Explored → do
            active_worker_ids ← Map.keys . Map.delete worker_id <$> use active_workers
            unless (null active_worker_ids) . throw $
                ActiveWorkersRemainedAfterSpaceFullyExplored active_worker_ids
            SupervisorOutcome
                <$> (return $ SupervisorCompleted new_results)
                <*> (lift getCurrentStatistics)
                <*> (Set.toList <$> use known_workers)
             >>= abort
        _ → lift $ do
                deactivateWorker False worker_id
                unless remove_worker $ do
                    endWorkerOccupied worker_id
                    tryToObtainWorkloadFor False worker_id
-- }}}

retireManyOccupationStatistics :: (Functor f, SupervisorMonadConstraint m) ⇒ f OccupationStatistics → m (f RetiredOccupationStatistics) -- {{{
retireManyOccupationStatistics occupied_statistics =
    liftIO getCurrentTime >>= \current_time → return $
    fmap (\o → mempty
        & occupied_time .~ (o^.total_occupied_time + if o^.is_currently_occupied then current_time `diffUTCTime` (o^.last_occupied_change_time) else 0)
        & total_time .~ (current_time `diffUTCTime` (o^.start_time))
    ) occupied_statistics
-- }}}

retireOccupationStatistics :: SupervisorMonadConstraint m ⇒ OccupationStatistics → m RetiredOccupationStatistics -- {{{
retireOccupationStatistics = fmap head . retireManyOccupationStatistics . (:[])
-- }}}

removeWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
removeWorker worker_id = postValidate ("removeWorker " ++ show worker_id) $ do
    infoM $ "Removing worker " ++ show worker_id
    validateWorkerKnown "removing the worker" worker_id
    retireAndDeactivateWorker worker_id
-- }}}

removeWorkerIfPresent :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
removeWorkerIfPresent worker_id = postValidate ("removeWorker " ++ show worker_id) $ do
    whenM (Set.member worker_id <$> use known_workers) $ do
        infoM $ "Removing worker " ++ show worker_id
        retireAndDeactivateWorker worker_id
-- }}}

retireWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
retireWorker worker_id = do
    known_workers %= Set.delete worker_id
    retired_occupation_statistics ←
        worker_occupation_statistics %%= (fromJust . Map.lookup worker_id &&& Map.delete worker_id)
        >>=
        retireOccupationStatistics
    retired_worker_occupation_statistics %= Map.alter (
        Just . maybe retired_occupation_statistics (<> retired_occupation_statistics)
     ) worker_id
-- }}}

retireAndDeactivateWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorContext result worker_id m ()
retireAndDeactivateWorker worker_id = do
    retireWorker worker_id
    ifM (isJust . Map.lookup worker_id <$> use active_workers)
        (deactivateWorker True worker_id)
        (waiting_workers_or_available_workloads %%=
            either (pred . Map.size &&& Left . Map.delete worker_id)
                   (error $ "worker " ++ show worker_id ++ " is inactive but was not in the waiting queue")
         >>= updateTimeWeightedCountStatisticsUsingLens waiting_worker_count_statistics
        )
-- }}}

runSupervisorStartingFrom :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Progress result →
    SupervisorCallbacks result worker_id m →
    (∀ α. SupervisorAbortMonad result worker_id m α) →
    m (SupervisorOutcome result worker_id)
runSupervisorStartingFrom starting_progress actions program = liftIO getCurrentTime >>= \start_time →
    flip runReaderT actions
    .
    flip evalStateT
        (SupervisorState
            {   _waiting_workers_or_available_workloads =
                    Right . Set.singleton $ Workload Seq.empty (progressCheckpoint starting_progress)
            ,   _known_workers = mempty
            ,   _active_workers = mempty
            ,   _current_steal_depth = 0
            ,   _available_workers_for_steal = mempty
            ,   _workers_pending_workload_steal = mempty
            ,   _workers_pending_progress_update = mempty
            ,   _current_progress = starting_progress
            ,   _debug_mode = False
            ,   _supervisor_occupation_statistics = OccupationStatistics
                {   _start_time = start_time
                ,   _last_occupied_change_time = start_time
                ,   _total_occupied_time = 0
                ,   _is_currently_occupied = False
                }
            ,   _worker_occupation_statistics = mempty
            ,   _retired_worker_occupation_statistics = mempty
            ,   _worker_wait_time_statistics = mempty
            ,   _waiting_worker_count_statistics = initialTimeWeightedCountStatisticsForStartingTime start_time
            ,   _available_workload_count_statistics = initialTimeWeightedCountStatisticsForStartingTime start_time
            }
        )
    .
    runAbortT
    $
    program
-- }}}

sendCurrentProgressToUser :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorContext result worker_id m ()
sendCurrentProgressToUser = do
    callback ← asks receiveCurrentProgress
    current_progress ← use current_progress
    liftUserToContext (callback current_progress)
-- }}}

sendWorkloadTo :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Workload →
    worker_id →
    SupervisorContext result worker_id m ()
sendWorkloadTo workload worker_id = do
    infoM $ "Sending workload to " ++ show worker_id
    asks sendWorkloadToWorker >>= liftUserToContext . (\f → f workload worker_id)
    isNothing . Map.lookup worker_id <$> use active_workers
        >>= flip unless (throw $ WorkerAlreadyHasWorkload worker_id)
    active_workers %= Map.insert worker_id workload
    beginWorkerOccupied worker_id
    enqueueWorkerForSteal worker_id
    checkWhetherMoreStealsAreNeeded
-- }}}

setSupervisorDebugMode :: SupervisorMonadConstraint m ⇒ Bool → SupervisorContext result worker_id m () -- {{{
setSupervisorDebugMode = (debug_mode .=)
-- }}}

timePassedSince :: SupervisorMonadConstraint m ⇒ UTCTime → m NominalDiffTime -- {{{
timePassedSince = (<$> liftIO getCurrentTime) . flip diffUTCTime
-- }}}

tryGetWaitingWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorContext result worker_id m (Maybe worker_id)
tryGetWaitingWorker =
    either (fmap (fst . fst) . Map.minViewWithKey) (const Nothing)
    <$>
    use waiting_workers_or_available_workloads
-- }}}

tryToObtainWorkloadFor :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Bool →
    worker_id →
    SupervisorContext result worker_id m ()
tryToObtainWorkloadFor is_new_worker worker_id =
    use waiting_workers_or_available_workloads
    >>=
    \x → case x of
        Left waiting_workers → do
            maybe_time_started_waiting ← getMaybeTimeStartedWorking
            waiting_workers_or_available_workloads .= Left (Map.insert worker_id maybe_time_started_waiting waiting_workers)
            checkWhetherMoreStealsAreNeeded
            updateTimeWeightedCountStatisticsUsingLens waiting_worker_count_statistics (Map.size waiting_workers + 1)
        Right (Set.minView → Nothing) → do
            maybe_time_started_waiting ← getMaybeTimeStartedWorking
            waiting_workers_or_available_workloads .= Left (Map.singleton worker_id maybe_time_started_waiting)
            checkWhetherMoreStealsAreNeeded
            updateTimeWeightedCountStatisticsUsingLens waiting_worker_count_statistics 1
        Right (Set.minView → Just (workload,remaining_workloads)) → do
            sendWorkloadTo workload worker_id
            waiting_workers_or_available_workloads .= Right remaining_workloads
            updateTimeWeightedCountStatisticsUsingLens available_workload_count_statistics (Set.size remaining_workloads + 1)
  where
    getMaybeTimeStartedWorking
      | is_new_worker = return Nothing
      | otherwise = Just <$> liftIO getCurrentTime

-- }}}

updateTimeWeightedCountStatistics :: UTCTime → Int → TimeWeightedCountStatistics → TimeWeightedCountStatistics -- {{{
updateTimeWeightedCountStatistics current_time value = execState $ do
    last_time ← previous_time <<.= current_time
    last_value ← previous_value <<.= value
    let weight = fromRational . toRational $ (current_time `diffUTCTime` last_time)
        last_value_as_double = fromRational . toRational $ last_value
    first_moment += weight*last_value_as_double
    second_moment += weight*last_value_as_double*last_value_as_double
    minimum_value %= min value
    maximum_value %= max value
-- }}}

updateTimeWeightedCountStatisticsUsingLens :: -- {{{
    MonadIO m ⇒
    Lens (SupervisorState result worker_id) (SupervisorState result worker_id) TimeWeightedCountStatistics TimeWeightedCountStatistics →
    Int →
    SupervisorContext result worker_id m ()
updateTimeWeightedCountStatisticsUsingLens field value =
    liftIO getCurrentTime >>= \current_time → field %= updateTimeWeightedCountStatistics current_time value
-- }}}

validateWorkerKnown :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    String →
    worker_id →
    SupervisorContext result worker_id m ()
validateWorkerKnown action worker_id =
    Set.notMember worker_id <$> (use known_workers)
        >>= flip when (throw $ WorkerNotKnown action worker_id)
-- }}}

validateWorkerKnownAndActive :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    String →
    worker_id →
    SupervisorContext result worker_id m ()
validateWorkerKnownAndActive action worker_id = do
    validateWorkerKnown action worker_id
    Set.notMember worker_id <$> (use known_workers)
        >>= flip when (throw $ WorkerNotActive action worker_id)
-- }}}

validateWorkerNotKnown :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    String →
    worker_id →
    SupervisorContext result worker_id m ()
validateWorkerNotKnown action worker_id = do
    Set.member worker_id <$> (use known_workers)
        >>= flip when (throw $ WorkerAlreadyKnown action worker_id)
-- }}}

whenDebugging :: SupervisorMonadState worker_id result m ⇒ m () → m () -- {{{
whenDebugging action = use debug_mode >>= flip when action
-- }}}

-- }}}
