-- Language extensions {{{
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}
-- }}}

module Control.Visitor.Workload where

-- Imports {{{
import Control.Monad (join,liftM)
import Data.Composition ((.*),(.**))
import Data.Derive.Serialize
import Data.DeriveTH
import Data.Function (on)
import Data.Monoid (Monoid(..))
import qualified Data.Sequence as Seq
import Data.Serialize

import Control.Visitor
import Control.Visitor.Checkpoint
import Control.Visitor.Path
-- }}}

-- Types {{{

data Workload = Workload -- {{{
    {   workloadPath :: Path
    ,   workloadCheckpoint :: Checkpoint
    } deriving (Eq,Show)
$( derive makeSerialize ''Workload )
-- }}}

-- }}}

-- Instances {{{
instance Ord Workload where
    x `compare` y =
        case (compare `on` workloadDepth) x y of
            EQ → case (compare `on` workloadPath) x y of
                EQ → (compare `on` workloadCheckpoint) x y
                c → c
            c → c
-- }}}

-- Values {{{

entire_workload :: Workload
entire_workload = Workload Seq.empty Unexplored

-- }}}

-- Functions {{{

runVisitorThroughWorkload :: -- {{{
    Monoid α ⇒
    Workload →
    Visitor α →
    α
runVisitorThroughWorkload =
    (fst . last)
    .*
    walkVisitorThroughWorkload
-- }}}

runVisitorTThroughWorkload :: -- {{{
    (Monad m, Monoid α) ⇒
    Workload →
    VisitorT m α →
    m α
runVisitorTThroughWorkload = gatherResults .* walkVisitorTThroughWorkload
-- }}}

runVisitorUntilFirstThroughWorkload :: -- {{{
    Workload →
    Visitor α →
    Maybe α
runVisitorUntilFirstThroughWorkload =
    fetchFirstResult
    .*
    walkVisitorUntilFirstThroughWorkload
-- }}}

runVisitorTUntilFirstThroughWorkload :: -- {{{
    Monad m ⇒
    Workload →
    VisitorT m α →
    m (Maybe α)
runVisitorTUntilFirstThroughWorkload =
    fetchFirstResultT
    .*
    walkVisitorTUntilFirstThroughWorkload
-- }}}

runVisitorUntilFoundThroughWorkload :: -- {{{
    Monoid α ⇒
    (α → Maybe β) →
    Workload →
    Visitor α →
    Either α β
runVisitorUntilFoundThroughWorkload =
    fetchFoundResult
    .**
    walkVisitorUntilFoundThroughWorkload
-- }}}

runVisitorTUntilFoundThroughWorkload :: -- {{{
    (Monoid α, Monad m) ⇒
    (α → Maybe β) →
    Workload →
    VisitorT m α →
    m (Either α β)
runVisitorTUntilFoundThroughWorkload =
    fetchFoundResultT
    .**
    walkVisitorTUntilFoundThroughWorkload
-- }}}

walkVisitorThroughWorkload :: -- {{{
    Monoid α ⇒
    Workload →
    Visitor α →
    [(α,Checkpoint)]
walkVisitorThroughWorkload Workload{..} =
    walkVisitorThroughCheckpoint workloadCheckpoint
    .
    sendVisitorDownPath workloadPath
-- }}}

walkVisitorTThroughWorkload :: -- {{{
    (Monad m, Monoid α) ⇒
    Workload →
    VisitorT m α →
    ResultFetcher m α
walkVisitorTThroughWorkload Workload{..} =
    ResultFetcher
    .
    join
    .
    liftM (
        fetchResult
        .
        walkVisitorTThroughCheckpoint workloadCheckpoint
    )
    .
    sendVisitorTDownPath workloadPath
-- }}}

walkVisitorUntilFirstThroughWorkload :: -- {{{
    Workload →
    Visitor α →
    FirstResultFetcher α
walkVisitorUntilFirstThroughWorkload Workload{..} =
    walkVisitorUntilFirstThroughCheckpoint workloadCheckpoint
    .
    sendVisitorDownPath workloadPath
-- }}}

walkVisitorTUntilFirstThroughWorkload :: -- {{{
    Monad m ⇒
    Workload →
    VisitorT m α →
    FirstResultFetcherT m α
walkVisitorTUntilFirstThroughWorkload Workload{..} =
    FirstResultFetcherT
    .
    join
    .
    liftM (
        firstResultFetcher
        .
        walkVisitorTUntilFirstThroughCheckpoint workloadCheckpoint
    )
    .
    sendVisitorTDownPath workloadPath
-- }}}

walkVisitorUntilFoundThroughWorkload :: -- {{{
    Monoid α ⇒
    (α → Maybe β) →
    Workload →
    Visitor α →
    FoundResultFetcher α β
walkVisitorUntilFoundThroughWorkload f Workload{..} =
    walkVisitorUntilFoundThroughCheckpoint f workloadCheckpoint
    .
    sendVisitorDownPath workloadPath
-- }}}

walkVisitorTUntilFoundThroughWorkload :: -- {{{
    (Monoid α, Monad m) ⇒
    (α → Maybe β) →
    Workload →
    VisitorT m α →
    FoundResultFetcherT m α β
walkVisitorTUntilFoundThroughWorkload f Workload{..} =
    FoundResultFetcherT
    .
    join
    .
    liftM (
        foundResultFetcher
        .
        walkVisitorTUntilFoundThroughCheckpoint f workloadCheckpoint
    )
    .
    sendVisitorTDownPath workloadPath
-- }}}

workloadDepth :: Workload → Int -- {{{
workloadDepth = Seq.length . workloadPath -- }}}

-- }}}
