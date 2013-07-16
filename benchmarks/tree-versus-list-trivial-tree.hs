-- Language extensions {{{
{-# LANGUAGE UnicodeSyntax #-}
-- }}}

-- Imports {{{
import Criterion.Main
import Data.Monoid

import Visitor
import Visitor.Checkpoint
import Visitor.Utils.PerfectTree
import Visitor.Utils.WordSum
import Visitor.Parallel.Common.ExplorationMode (ExplorationMode(AllMode))
import Visitor.Parallel.Common.Worker (Purity(Pure),exploreTreeGeneric)
-- }}}

main = defaultMain
    [bench "list" $ nf (getWordSum . mconcat . trivialPerfectTree 2) depth
    ,bench "tree" $ nf (getWordSum . exploreTree . trivialPerfectTree 2) depth
    ,bench "tree w/ checkpointing" $ nf (getWordSum . exploreTreeStartingFromCheckpoint Unexplored . trivialPerfectTree 2) depth
    ,bench "tree using worker" $ exploreTreeGeneric AllMode Pure (trivialPerfectTree 2 depth)
    ]
  where depth = 15
