import Control.Monad.IO.Class (liftIO)
import Data.Monoid (mempty)
import GHC.Conc (setNumCapabilities)
import System.Exit (exitFailure,exitSuccess)

import LogicGrowsOnTrees.Checkpoint (Progress(..))
import LogicGrowsOnTrees.Parallel.Adapter.Threads
    (RunOutcome(..)
    ,TerminationReason(..)
    ,abort
    ,exploreTreeStartingFrom
    ,requestProgressUpdate
    ,setNumberOfWorkers
    )
import LogicGrowsOnTrees.Utils.WordSum (WordSum(..))
import LogicGrowsOnTrees.Examples.Queens (nqueensUsingBitsSolutions)

main = setNumCapabilities 2 >> go mempty
 where
  go progress@(Progress _ (WordSum count)) = do
    putStrLn $ "Counting... (starting with " ++ show count ++ " solutions); press <Enter> to abort"
    RunOutcome statistics termination_reason <-
        exploreTreeStartingFrom
            progress
            (do setNumberOfWorkers 2
                _ <- liftIO $ getLine
                _ <- requestProgressUpdate
                abort
            )
        .
        fmap (const $ WordSum 1)
        .
        nqueensUsingBitsSolutions
        $
        14
    case termination_reason of
        Aborted progress -> do
            putStrLn $ "Count aborted; will try again."
            go progress
        Completed (WordSum count) -> do
            putStrLn $ "Found " ++ show count ++ " solutions."
            exitSuccess
        Failure progress message -> do
            putStrLn $ "Failed: " ++ message
            exitFailure