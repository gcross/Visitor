{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

{-| This module contains functions that let one easily implement the worker side
    of a back-end under the assumption that the worker uses a two-way
    communication channel with the supervisor for sending and receiving
    messages.  (Examples of when this is NOT the case is the threads back-end,
    where you can communicate with the worker threads directly, and the MPI
    back-end, which has communication primitives that don't quite align with
    this setup.)

    Note:  This module is used by the processes and network back-end, which are
           provided in separate packages.
 -}
module Visitor.Parallel.Common.Process
    ( runWorker
    , runWorkerUsingHandles
    ) where

import Control.Concurrent (killThread)
import Control.Concurrent.MVar (isEmptyMVar,newEmptyMVar,newMVar,putMVar,takeMVar,tryTakeMVar,withMVar)
import Control.Exception (AsyncException(ThreadKilled,UserInterrupt),catchJust)
import Control.Monad.IO.Class

import Data.Functor ((<$>))
import Data.Serialize
import Data.Void (absurd)

import System.IO (Handle)
import qualified System.Log.Logger as Logger
import System.Log.Logger (Priority(DEBUG,INFO))
import System.Log.Logger.TH

import Visitor (TreeGeneratorT)
import Visitor.Parallel.Common.Message (MessageForSupervisor(..),MessageForSupervisorForMode(..),MessageForWorker(..))
import Visitor.Parallel.Common.VisitorMode (ProgressFor(..),ResultFor(..),VisitorMode(..),WorkerFinalProgressFor(..))
import Visitor.Parallel.Common.Worker hiding (ProgressUpdate,StolenWorkload)
import Visitor.Utils.Handle
import Visitor.Workload

--------------------------------------------------------------------------------
----------------------------------- Loggers ------------------------------------
--------------------------------------------------------------------------------

deriveLoggers "Logger" [DEBUG,INFO]

--------------------------------------------------------------------------------
----------------------------------- Functions ----------------------------------
--------------------------------------------------------------------------------

{-| Runs a loop that continually fetches and reacts to messages from the
    supervisor until the worker quits.
 -}
runWorker ::
    ∀ visitor_mode m n.
    VisitorMode visitor_mode {-^ the mode in to visit the tree -} →
    Purity m n {-^ the purity of the tree generator -} →
    TreeGeneratorT m (ResultFor visitor_mode) {-^ the tree generator -} →
    IO MessageForWorker {-^ the action used to fetch the next message -} →
    (MessageForSupervisorForMode visitor_mode → IO ()) {-^ the action to send a message to the supervisor;  note that this might occur in a different thread from the worker loop -} →
    IO () {-^ an IO action that loops processing messages until it is quit, at which point it returns -}
runWorker visitor_mode purity tree_generator receiveMessage sendMessage =
    -- Note:  This an MVar rather than an IORef because it is used by two
    --        threads --- this one and the worker thread --- and I wanted to use
    --        a mechanism that ensured that the new value would be observed by
    --        the other thread immediately rather than when the cache lines
    --        are flushed to the other processors.
    newEmptyMVar >>= \worker_environment_mvar →
    let processRequest ::
            (WorkerRequestQueue (ProgressFor visitor_mode) → (α → IO ()) → IO ()) →
            (α → MessageForSupervisorForMode visitor_mode) →
            IO ()
        processRequest sendRequest constructResponse =
            tryTakeMVar worker_environment_mvar
            >>=
            maybe (return ()) (\worker_environment@WorkerEnvironment{workerPendingRequests} → do
                _ ← sendRequest workerPendingRequests (sendMessage . constructResponse)
                putMVar worker_environment_mvar worker_environment
            )
        processNextMessage = receiveMessage >>= \message →
            case message of
                RequestProgressUpdate → do
                    processRequest sendProgressUpdateRequest ProgressUpdate
                    processNextMessage
                RequestWorkloadSteal → do
                    processRequest sendWorkloadStealRequest StolenWorkload
                    processNextMessage
                StartWorkload workload → do
                    infoM "Received workload."
                    debugM $ "Workload is: " ++ show workload
                    worker_is_running ← not <$> isEmptyMVar worker_environment_mvar
                    if worker_is_running
                        then sendMessage $ Failed "received a workload when the worker was already running"
                        else forkWorkerThread
                                visitor_mode
                                purity
                                (\termination_reason → do
                                    _ ← takeMVar worker_environment_mvar
                                    case termination_reason of
                                        WorkerFinished final_progress →
                                            sendMessage $ Finished final_progress
                                        WorkerFailed exception →
                                            sendMessage $ Failed (show exception)
                                        WorkerAborted →
                                            return ()
                                )
                                tree_generator
                                workload
                                (case visitor_mode of
                                    AllMode → absurd
                                    FirstMode → absurd
                                    FoundModeUsingPull _ → absurd
                                    FoundModeUsingPush _ → sendMessage . ProgressUpdate
                                )
                             >>=
                             putMVar worker_environment_mvar
                    processNextMessage
                QuitWorker → do
                    sendMessage WorkerQuit
                    liftIO $
                        tryTakeMVar worker_environment_mvar
                        >>=
                        maybe (return ()) (killThread . workerThreadId)
    in catchJust
        (\e → case e of
            ThreadKilled → Just ()
            UserInterrupt → Just ()
            _ → Nothing
        )
        processNextMessage
        (const $ return ())

{-| This function is the same as 'runWorker', but it lets you provide handles
    through which the messages will be sent and received.  (Note that the
    reading and writing handles might be the same.)
 -}
runWorkerUsingHandles ::
    ( Serialize (ProgressFor visitor_mode)
    , Serialize (WorkerFinalProgressFor visitor_mode)
    ) ⇒
    VisitorMode visitor_mode {-^ the mode in to visit the tree -} →
    Purity m n {-^ the purity of the tree generator -} →
    TreeGeneratorT m (ResultFor visitor_mode) {-^ the tree generator -} →
    Handle {-^ handle from which messages from the supervisor are read -} →
    Handle {-^ handle to which messages to the supervisor are written -} →
    IO () {-^ an IO action that loops processing messages until it is quit, at which point it returns -}
runWorkerUsingHandles visitor_mode purity tree_generator receive_handle send_handle =
    newMVar () >>= \send_lock →
    runWorker
        visitor_mode
        purity
        tree_generator
        (receive receive_handle)
        (withMVar send_lock . const . send send_handle)
