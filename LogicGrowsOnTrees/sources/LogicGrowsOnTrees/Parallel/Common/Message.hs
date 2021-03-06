{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

{-| This module contains infrastructure for communicating with workers over an
    inter-process channel.
 -}
module LogicGrowsOnTrees.Parallel.Common.Message
    (
    -- * Types
      MessageForSupervisor(..)
    , MessageForSupervisorFor
    , MessageForSupervisorReceivers(..)
    , MessageForWorker(..)
    -- * Functions
    , receiveAndProcessMessagesFromWorker
    , receiveAndProcessMessagesFromWorkerUsingHandle
    ) where

import Data.Serialize

import GHC.Generics (Generic)

import qualified LogicGrowsOnTrees.Parallel.Common.Worker as Worker
import LogicGrowsOnTrees.Parallel.ExplorationMode
import LogicGrowsOnTrees.Utils.Handle
import LogicGrowsOnTrees.Workload

import System.IO (Handle)

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

{-| A message from a worker to the supervisor;  the worker id is assumed to be
    known based on from where the message was received.
 -}
data MessageForSupervisor progress worker_final_progress =
    {-| The worker encountered a failure with the given message while exploring the tree. -}
    Failed String
    {-| The worker has finished with the given final progress. -}
  | Finished worker_final_progress
    {-| The worker has responded to the progress update request with the given progress update. -}
  | ProgressUpdate (Worker.ProgressUpdate progress)
    {-| The worker has responded to the workload steal request with possibly the stolen workload (and 'Nothing' if it was not possible to steal a workload at this time). -}
  | StolenWorkload (Maybe (Worker.StolenWorkload progress))
    {-| The worker has quit the system and is no longer available -}
  | WorkerQuit
  deriving (Eq,Generic,Show)
instance (Serialize α, Serialize β) ⇒ Serialize (MessageForSupervisor α β) where

{-| Convenient type alias for the 'MessageForSupervisor' type for the given exploration mode. -}
type MessageForSupervisorFor exploration_mode = MessageForSupervisor (ProgressFor exploration_mode) (WorkerFinishedProgressFor exploration_mode)

{-| This data structure contains callbacks to be invoked when a message has
    been received, depending on the kind of message.
 -}
data MessageForSupervisorReceivers exploration_mode worker_id = MessageForSupervisorReceivers
    {   {-| to be called when a progress update has been received from a worker -}
        receiveProgressUpdateFromWorker :: worker_id → Worker.ProgressUpdate (ProgressFor exploration_mode) → IO ()
        {-| to be called when a (possibly) stolen workload has been received from a worker -}
    ,   receiveStolenWorkloadFromWorker :: worker_id → Maybe (Worker.StolenWorkload (ProgressFor exploration_mode)) → IO ()
        {-| to be called when a failure (with the given message) has been received from a worker -}
    ,   receiveFailureFromWorker :: worker_id → String → IO ()
        {-| to be called when a worker has finished with the given final progress -}
    ,   receiveFinishedFromWorker :: worker_id → WorkerFinishedProgressFor exploration_mode → IO ()
        {-| to be called when a worker has quit the system and is no longer available -}
    ,   receiveQuitFromWorker :: worker_id → IO ()
    }

{-| A message from the supervisor to a worker.

    NOTE: It is your responsibility not to send a workload to a worker that
          already has one;  if you do then the worker will report an error and
          then terminate.  The converse, however, is not true:  it is okay to
          send a progress request to a worker without a workload because the
          worker might have finished between when you sent the message and when
          it was received.
 -}
data MessageForWorker =
    RequestProgressUpdate {-^ request a progress update -}
  | RequestWorkloadSteal {-^ request a stolen workload -}
  | StartWorkload Workload {-^ start exploring the given workload -}
  | QuitWorker {-^ stop what you are doing and quit the system -}
  deriving (Eq,Generic,Show)
instance Serialize MessageForWorker where

{-| Continually performs the given IO action to read a message from a worker
    with the given id and calls one of the given callbacks depending on the
    content of the message.
 -}
receiveAndProcessMessagesFromWorker ::
    MessageForSupervisorReceivers exploration_mode worker_id {-^ the callbacks to invoke when a message has been received -} →
    IO (MessageForSupervisorFor exploration_mode) {-^ an action that fetches the next message -} →
    worker_id {-^ the id of the worker from which messages are being received -} →
    IO () {-^ an IO action that continually processes incoming messages from a worker until it quits, at which point it returns -}
receiveAndProcessMessagesFromWorker
    MessageForSupervisorReceivers{..}
    receiveMessage
    worker_id
    = receiveNextMessage
  where
    receiveNextMessage = receiveMessage >>= processMessage
    processMessage (Failed message) = do
        receiveFailureFromWorker worker_id message
        receiveNextMessage
    processMessage (Finished final_progress) = do
        receiveFinishedFromWorker worker_id final_progress
        receiveNextMessage
    processMessage (ProgressUpdate progress_update) = do
        receiveProgressUpdateFromWorker worker_id progress_update
        receiveNextMessage
    processMessage (StolenWorkload stolen_workload) = do
        receiveStolenWorkloadFromWorker worker_id stolen_workload
        receiveNextMessage
    processMessage WorkerQuit =
        receiveQuitFromWorker worker_id

{-| The same as 'receiveAndProcessMessagesFromWorker' except that instead of
    giving it an IO action to fetch a message you provide a 'Handle' from which
    messsages (assumed to be deserializable) are read.
 -}
receiveAndProcessMessagesFromWorkerUsingHandle ::
    ( Serialize (ProgressFor exploration_mode)
    , Serialize (WorkerFinishedProgressFor exploration_mode)
    ) ⇒
    MessageForSupervisorReceivers exploration_mode worker_id {-^ the callbacks to invoke when a message has been received -} →
    Handle {-^ the handle from which messages should be read -} →
    worker_id {-^ the id of the worker from which messages are being received -} →
    IO () {-^ an IO action that continually processes incoming messages from a worker until it quits, at which point it returns -}
receiveAndProcessMessagesFromWorkerUsingHandle receivers handle worker_id =
    receiveAndProcessMessagesFromWorker receivers (receive handle) worker_id



