-- Language extensions {{{
{-# LANGUAGE UnicodeSyntax #-}
-- }}}

-- Imports {{{
import Criterion.Main
import Data.Monoid

import Visitor
import Visitor.Checkpoint
import Visitor.Examples.Queens
import Visitor.Utils.WordSum
import Visitor.Parallel.Common.ExplorationMode (ExplorationMode(AllMode))
import Visitor.Parallel.Common.Worker (Purity(Pure),visitTreeGeneric)
-- }}}

main = defaultMain
    [bench "list of Sum" $ nf (getWordSum . mconcat . nqueensCount) n
    ,bench "tree generator" $ nf (getWordSum . visitTree . nqueensCount) n
    ,bench "tree generator w/ checkpointing" $ nf (getWordSum . visitTreeStartingFromCheckpoint Unexplored . nqueensCount) n
    ,bench "tree generator using worker" $ visitTreeGeneric AllMode Pure (nqueensCount n)
    ]
  where n = 13