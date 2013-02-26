-- Language extensions {{{
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-} -- needed to define the MTL instances :-/
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}
-- }}}

module Control.Visitor.Supervisor -- {{{
    ( RunStatistics(..)
    , Statistics(..)
    , SupervisorCallbacks(..)
    , SupervisorFullConstraint
    , SupervisorMonad
    , SupervisorMonadConstraint
    , SupervisorOutcome(..)
    , SupervisorProgram(..)
    , SupervisorTerminationReason(..)
    , SupervisorWorkerIdConstraint
    , TimeStatistics(..)
    , abortSupervisor
    , addWorker
    , disableSupervisorDebugMode
    , enableSupervisorDebugMode
    , getCurrentProgress
    , getCurrentStatistics
    , getNumberOfWorkers
    , performGlobalProgressUpdate
    , receiveProgressUpdate
    , receiveStolenWorkload
    , receiveWorkerFailure
    , receiveWorkerFinished
    , receiveWorkerFinishedAndRemoved
    , receiveWorkerFinishedWithRemovalFlag
    , removeWorker
    , removeWorkerIfPresent
    , runSupervisor
    , runSupervisorMaybeStartingFrom
    , runSupervisorStartingFrom
    , runUnrestrictedSupervisor
    , runUnrestrictedSupervisorMaybeStartingFrom
    , runUnrestrictedSupervisorStartingFrom
    , setSupervisorDebugMode
    , tryGetWaitingWorker
    ) where -- }}}

-- Imports {{{
import Control.Applicative (Applicative)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader.Class (MonadReader(..))
import Control.Monad.State.Class (MonadState(..))
import Control.Monad.Trans.Class (MonadTrans(..))

import Data.Composition ((.*),(.**))
import Data.Monoid (Monoid(mempty))

import Control.Visitor.Checkpoint (Progress)
import Control.Visitor.Worker (ProgressUpdate,StolenWorkload)

import qualified Control.Visitor.Supervisor.Implementation as Implementation
import Control.Visitor.Supervisor.Implementation -- {{{
    ( RunStatistics(..)
    , Statistics(..)
    , SupervisorAbortMonad()
    , SupervisorCallbacks(..)
    , SupervisorFullConstraint
    , SupervisorMonadConstraint
    , SupervisorOutcome(..)
    , SupervisorTerminationReason(..)
    , SupervisorWorkerIdConstraint
    , TimeStatistics(..)
    , liftUserToContext
    , localWithinContext
    ) -- }}}
-- }}}

-- Types {{{

newtype SupervisorMonad result worker_id m α = -- {{{
    SupervisorMonad {
        unwrapSupervisorMonad :: SupervisorAbortMonad result worker_id m α
    } deriving (Applicative,Functor,Monad,MonadIO)
-- }}}

data SupervisorProgram result worker_id m = -- {{{
    ∀ α. BlockingProgram (SupervisorMonad result worker_id m ()) (m α) (α → SupervisorMonad result worker_id m ())
  | ∀ α. PollingProgram (SupervisorMonad result worker_id m ()) (m (Maybe α)) (α → SupervisorMonad result worker_id m ())
  | UnrestrictedProgram (∀ α. SupervisorMonad result worker_id m α)
-- }}}

-- }}}

-- Instances {{{

instance MonadTrans (SupervisorMonad result worker_id) where -- {{{
    lift = SupervisorMonad . lift . liftUserToContext
-- }}}

instance MonadReader r m ⇒ MonadReader r (SupervisorMonad result worker_id m) where -- {{{
    ask = lift ask
    local f = SupervisorMonad . Implementation.localWithinAbort f . unwrapSupervisorMonad
-- }}}

instance MonadState s m ⇒ MonadState s (SupervisorMonad result worker_id m) where -- {{{
    get = lift get
    put = lift . put
-- }}}

-- }}}

-- Exposed functions {{{

abortSupervisor :: SupervisorFullConstraint worker_id m ⇒ SupervisorMonad result worker_id m α -- {{{
abortSupervisor = SupervisorMonad $ Implementation.abortSupervisor
-- }}}

addWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorMonad result worker_id m ()
addWorker = SupervisorMonad . lift . Implementation.addWorker
-- }}}

beginSupervisorOccupied :: SupervisorMonadConstraint m ⇒ SupervisorMonad result worker_id m () -- {{{
beginSupervisorOccupied = changeSupervisorOccupiedStatus True
-- }}}

changeSupervisorOccupiedStatus :: SupervisorMonadConstraint m ⇒ Bool → SupervisorMonad result worker_id m () -- {{{
changeSupervisorOccupiedStatus = SupervisorMonad . lift . Implementation.changeSupervisorOccupiedStatus
-- }}}

disableSupervisorDebugMode :: SupervisorMonadConstraint m ⇒ SupervisorMonad result worker_id m () -- {{{
disableSupervisorDebugMode = setSupervisorDebugMode False
-- }}}

enableSupervisorDebugMode :: SupervisorMonadConstraint m ⇒ SupervisorMonad result worker_id m () -- {{{
enableSupervisorDebugMode = setSupervisorDebugMode True
-- }}}

endSupervisorOccupied :: SupervisorMonadConstraint m ⇒ SupervisorMonad result worker_id m () -- {{{
endSupervisorOccupied = changeSupervisorOccupiedStatus False
-- }}}

getCurrentProgress :: SupervisorMonadConstraint m ⇒ SupervisorMonad result worker_id m (Progress result) -- {{{
getCurrentProgress = SupervisorMonad . lift $ Implementation.getCurrentProgress
-- }}}

getCurrentStatistics :: -- {{{
    SupervisorFullConstraint worker_id m ⇒
    SupervisorMonad result worker_id m RunStatistics
getCurrentStatistics = SupervisorMonad . lift $ Implementation.getCurrentStatistics
-- }}}

getNumberOfWorkers :: SupervisorMonadConstraint m ⇒ SupervisorMonad result worker_id m Int -- {{{
getNumberOfWorkers = SupervisorMonad . lift $ Implementation.getNumberOfWorkers
-- }}}

performGlobalProgressUpdate :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorMonad result worker_id m ()
performGlobalProgressUpdate = SupervisorMonad . lift $ Implementation.performGlobalProgressUpdate
-- }}}

receiveProgressUpdate :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    ProgressUpdate result →
    SupervisorMonad result worker_id m ()
receiveProgressUpdate = (SupervisorMonad . lift) .* Implementation.receiveProgressUpdate
-- }}}

receiveStolenWorkload :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    Maybe (StolenWorkload result) →
    SupervisorMonad result worker_id m ()
receiveStolenWorkload = (SupervisorMonad . lift) .* Implementation.receiveStolenWorkload
-- }}}

receiveWorkerFailure :: SupervisorFullConstraint worker_id m ⇒ worker_id → String → SupervisorMonad result worker_id m α -- {{{
receiveWorkerFailure =
    (SupervisorMonad . Implementation.abortSupervisorWithReason)
    .*
    SupervisorFailure
-- }}}

receiveWorkerFinished :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    Progress result →
    SupervisorMonad result worker_id m ()
receiveWorkerFinished = receiveWorkerFinishedWithRemovalFlag False
-- }}}

receiveWorkerFinishedAndRemoved :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    Progress result →
    SupervisorMonad result worker_id m ()
receiveWorkerFinishedAndRemoved = receiveWorkerFinishedWithRemovalFlag True
-- }}}

receiveWorkerFinishedWithRemovalFlag :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Bool →
    worker_id →
    Progress result →
    SupervisorMonad result worker_id m ()
receiveWorkerFinishedWithRemovalFlag = SupervisorMonad .** Implementation.receiveWorkerFinishedWithRemovalFlag
-- }}}

removeWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorMonad result worker_id m ()
removeWorker = SupervisorMonad . lift . Implementation.removeWorker
-- }}}

removeWorkerIfPresent :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    worker_id →
    SupervisorMonad result worker_id m ()
removeWorkerIfPresent = SupervisorMonad . lift . Implementation.removeWorkerIfPresent
-- }}}

runSupervisor :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorCallbacks result worker_id m →
    SupervisorProgram result worker_id m →
    m (SupervisorOutcome result worker_id)
runSupervisor = runSupervisorStartingFrom mempty
-- }}}

runSupervisorMaybeStartingFrom :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Maybe (Progress result) →
    SupervisorCallbacks result worker_id m →
    SupervisorProgram result worker_id m →
    m (SupervisorOutcome result worker_id)
runSupervisorMaybeStartingFrom Nothing = runSupervisor
runSupervisorMaybeStartingFrom (Just progress) = runSupervisorStartingFrom progress
-- }}}

runSupervisorStartingFrom :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Progress result →
    SupervisorCallbacks result worker_id m →
    SupervisorProgram result worker_id m →
    m (SupervisorOutcome result worker_id)
runSupervisorStartingFrom starting_progress actions program =
    Implementation.runSupervisorStartingFrom
        starting_progress
        actions
        (unwrapSupervisorMonad . runSupervisorProgram $ program)
-- }}}

runSupervisorProgram :: SupervisorMonadConstraint m ⇒ SupervisorProgram result worker_id m → SupervisorMonad result worker_id m α -- {{{
runSupervisorProgram program =
    case program of
        BlockingProgram initialize getRequest processRequest → forever $ do
            initialize
            request ← lift getRequest
            beginSupervisorOccupied
            processRequest request
            endSupervisorOccupied
        PollingProgram initialize getMaybeRequest processRequest → initialize >> forever (do
            maybe_request ← lift getMaybeRequest
            case maybe_request of
                Nothing → endSupervisorOccupied
                Just request → do
                    beginSupervisorOccupied
                    processRequest request
         )
        UnrestrictedProgram run → run
-- }}}

runUnrestrictedSupervisor :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorCallbacks result worker_id m →
    (∀ α. SupervisorMonad result worker_id m α) →
    m (SupervisorOutcome result worker_id)
runUnrestrictedSupervisor callbacks = runSupervisorStartingFrom mempty callbacks . UnrestrictedProgram
-- }}}

runUnrestrictedSupervisorMaybeStartingFrom :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Maybe (Progress result) →
    SupervisorCallbacks result worker_id m →
    (∀ α. SupervisorMonad result worker_id m α) →
    m (SupervisorOutcome result worker_id)
runUnrestrictedSupervisorMaybeStartingFrom Nothing = runUnrestrictedSupervisor
runUnrestrictedSupervisorMaybeStartingFrom (Just progress) = runUnrestrictedSupervisorStartingFrom progress
-- }}}

runUnrestrictedSupervisorStartingFrom :: -- {{{
    ( Monoid result
    , SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    Progress result →
    SupervisorCallbacks result worker_id m →
    (∀ α. SupervisorMonad result worker_id m α) →
    m (SupervisorOutcome result worker_id)
runUnrestrictedSupervisorStartingFrom starting_progress actions =
    runSupervisorStartingFrom starting_progress actions . UnrestrictedProgram
-- }}}

setSupervisorDebugMode :: SupervisorMonadConstraint m ⇒ Bool → SupervisorMonad result worker_id m () -- {{{
setSupervisorDebugMode = SupervisorMonad . lift . Implementation.setSupervisorDebugMode
-- }}}

tryGetWaitingWorker :: -- {{{
    ( SupervisorMonadConstraint m
    , SupervisorWorkerIdConstraint worker_id
    ) ⇒
    SupervisorMonad result worker_id m (Maybe worker_id)
tryGetWaitingWorker = SupervisorMonad . lift $ Implementation.tryGetWaitingWorker
-- }}}

