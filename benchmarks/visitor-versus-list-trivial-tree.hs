-- Language extensions {{{
{-# LANGUAGE UnicodeSyntax #-}
-- }}}

-- Imports {{{
import Criterion.Main
import Data.Monoid

import Visitor
import Visitor.Checkpoint
import Visitor.Examples.Tree
import Visitor.Utils.WordSum
import qualified Visitor.Parallel.Common.Worker as Worker
-- }}}

main = defaultMain
    [bench "list" $ nf (getWordSum . mconcat . trivialTree 2) depth
    ,bench "visitor" $ nf (getWordSum . visitTree . trivialTree 2) depth
    ,bench "visitor w/ checkpointing" $ nf (getWordSum . visitTreeStartingFromCheckpoint Unexplored . trivialTree 2) depth
    ,bench "visitor using worker" $ Worker.visitTree (trivialTree 2 depth)
    ]
  where depth = 15
