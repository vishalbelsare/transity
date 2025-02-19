module Main where

import Prelude (Unit, bind, discard, pure, unit, (#), ($), (<#>), (<>), (/=), (>))

import Ansi.Codes (Color(..))
import Ansi.Output (withGraphics, foreground)
import Data.Array (concat, cons, difference, filter, null, zip, (!!))
import Data.Eq ((==))
import Data.Foldable (foldMap)
import Data.Maybe (Maybe(..))
import Data.Newtype (over)
import Data.Result (Result(..), note, isOk, fromEither)
import Data.String (Pattern(..), indexOf, length)
import Data.Traversable (for_, sequence)
import Data.Tuple (Tuple(..), fst, snd)
import Effect (Effect)
import Effect.Class.Console (log, error)
import Effect.Aff (launchAff_)
import Node.Encoding (Encoding(UTF8))
import Node.FS.Async (stat)
import Node.FS.Stats (isFile, isDirectory)
import Node.FS.Sync as Sync
import Node.Path as Path
import Node.Process (argv, cwd, exit)

import Transity.Data.Ledger (Ledger(..), BalanceFilter(..))
import Transity.Data.Ledger as Ledger
import Transity.Data.Transaction (Transaction(..))
import Transity.Plot as Plot
import Transity.Utils (ColorFlag(..), SortOrder(..))
import Transity.Xlsx (writeToZip, entriesAsXlsx)

type Config = { colorState :: ColorFlag }

config :: Config
config =
  { colorState: ColorYes
  }


usageString :: String
usageString = """
Usage: transity <command> <path/to/journal.yaml>

Command             Description
------------------  ------------------------------------------------------------
balance             Simple balance of the owner's accounts
balance-all         Simple balance of all accounts
transactions        All transactions and their transfers
transfers           All transfers with one transfer per line
entries             All individual deposits & withdrawals, space separated
entities            [WIP] List all referenced entities
entities-sorted     [WIP] List all referenced entities sorted alphabetically
ledger-entries      All entries in Ledger format
csv                 Transfers, comma separated (printed to stdout)
tsv                 Transfers, tab separated (printed to stdout)
xlsx                XLSX file with all transfers (printed to stdout)
entries-by-account  All individual deposits & withdrawals, grouped by account
gplot               Code and data for gnuplot impulse diagram
                      to visualize transfers of all accounts
gplot-cumul         Code and data for cumuluative gnuplot step chart
                      to visualize balance of all accounts
unused-files        Recursively list all files in a directory
                      which are not referenced in the journal
help                Print this help dialog
version             Print currently used version
"""


-- TODO: Move validation to parsing
utcError :: String
utcError =
  "All transfers or their parent transaction must have a valid UTC field"



run :: String -> String -> Ledger -> Result String String
run command filePathRel ledger =
  case command of
    "balance"            -> Ok $
      Ledger.showBalance BalanceOnlyOwner ColorYes ledger
    "balance-all"        -> Ok $ Ledger.showBalance BalanceAll ColorYes ledger
    -- "balance-on"         -> Ok $
    --   Ledger.showBalanceOn dateMaybe ColorYes ledger
    "transactions"       -> Ok $ Ledger.showPrettyAligned ColorYes ledger
    "transfers"          -> Ok $ Ledger.showTransfers ColorYes ledger
    "entries"            -> note utcError $ Ledger.showEntries  " " ledger
    "entities"           -> Ok $ Ledger.showEntities CustomSort ledger
    "entities-sorted"    -> Ok $ Ledger.showEntities Alphabetically ledger
    "ledger-entries"     -> Ok $ Ledger.entriesToLedger ledger
    "csv"                -> note utcError $ Ledger.showEntries  "," ledger
    "tsv"                -> note utcError $ Ledger.showEntries  "\t" ledger
    "entries-by-account" -> note utcError $ Ledger.showEntriesByAccount ledger
    "gplot" ->
      (note utcError $ Ledger.showEntriesByAccount ledger)
      <#> (\entries -> Plot.gplotCode $ Plot.configDefault
        # (Plot.GplotConfig `over` (_
            { data = entries
            , title = filePathRel
            })))
    "gplot-cumul" ->
      (note utcError $ Ledger.showEntriesByAccount ledger)
      <#> (\entries -> Plot.gplotCodeCumul $ Plot.configDefault
        # (Plot.GplotConfig `over` (_
            { data = entries
            , title = filePathRel <> " - Cumulative"
            })))

    other -> Error ("\"" <> other <> "\" is not a valid command")


-- | Asynchronously logs all non existent referenced files
checkFilePaths :: String -> Ledger -> Effect (Result String String)
checkFilePaths ledgerFilePath (Ledger {transactions}) = do
  let
    files = foldMap (\(Transaction tact) -> tact.files) transactions

  for_ files \filePathRel -> do
    filePathAbs <- Path.resolve [ledgerFilePath] filePathRel
    stat filePathAbs $ \statsResult ->
      if isOk $ fromEither statsResult
      then pure unit
      else
        log $ withGraphics
          (foreground Yellow)
          ("Warning: \"" <> filePathAbs <> "\" does not exist")

  pure $ Ok ""


loadAndExec
  :: String
  -> Array String
  -> Effect (Result String String)
loadAndExec currentDir [command, filePathRel] = do
  filePathAbs <- Path.resolve [currentDir] filePathRel
  ledgerFileContent <- Sync.readTextFile UTF8 filePathAbs

  case (Ledger.fromYaml ledgerFileContent) of
    Error msg -> pure $ Error msg
    Ok ledger -> do
      let
        journalDir =
          if indexOf (Pattern "/dev/fd/") filePathAbs == Just 0
          then currentDir
          else Path.dirname filePathAbs
      _ <- checkFilePaths journalDir ledger

      case command of
        "xlsx" -> do
          launchAff_ $ writeToZip
            Nothing  -- Means stdout
            (entriesAsXlsx ledger)
          pure (Ok "")
        _ ->
          pure $ run command filePathRel ledger

loadAndExec _ _ =
  pure $ Error "loadAndExec expects an array with length 2"


errorAndExit :: String -> Effect Unit
errorAndExit message = do
  error (if config.colorState == ColorYes
        then withGraphics (foreground Red) message
        else message)
  exit 1


getAllFiles :: String -> Effect (Array String)
getAllFiles directoryPath =
  let
    addFiles :: String -> Effect (Array String)
    addFiles dirPath = do
      entriesRel <- Sync.readdir dirPath
      let
        cleanEntriesRel = filter (_ /= ".DS_Store") entriesRel
        entriesAbs = cleanEntriesRel <#> (\entry -> dirPath <> "/" <> entry)
      statEntries <- sequence $ entriesAbs <#> Sync.stat

      let
        pathStatsTuples = zip entriesAbs statEntries
        fileTuples = filter (\tuple -> isFile $ snd tuple) pathStatsTuples
        dirTuples = filter (\tuple -> isDirectory $ snd tuple) pathStatsTuples
        files = fileTuples <#> fst

      if null dirTuples
      then
        pure $ files
      else do
        filesNested <- sequence $ dirTuples
          <#> (\(Tuple dir _) -> addFiles dir)
        pure (concat $ cons files filesNested)
  in
    addFiles directoryPath


main :: Effect Unit
main = do
  arguments <- argv

  case [arguments !! 2, arguments !! 3, arguments !! 4] of
    [Just "help",    Nothing, Nothing] -> log usageString
    [Just "version", Nothing, Nothing] -> log "0.8.0"

    [Just _,        Nothing, Nothing] ->
      errorAndExit $ "No path to a ledger file was provided\n\n" <> usageString

    [Just "unused-files", Just filesDirPath, Just ledgerFilePath] -> do
      ledgerFilePathAbs <- Path.resolve [] ledgerFilePath
      ledgerFileContent <- Sync.readTextFile UTF8 ledgerFilePathAbs

      case (Ledger.fromYaml ledgerFileContent) of
        Error msg -> errorAndExit msg
        Ok ledger@(Ledger {transactions}) -> do
          currentDir <- cwd
          let
            journalDir =
              if indexOf (Pattern "/dev/fd/") ledgerFilePathAbs == Just 0
              then currentDir
              else Path.dirname ledgerFilePathAbs
          _ <- checkFilePaths journalDir ledger

          filesDir <- Path.resolve [] filesDirPath
          foundFiles <- getAllFiles filesDir
          let
            ledgerFilesRel = foldMap
              (\(Transaction tact) -> tact.files)
              transactions
          ledgerFilesAbs <- sequence $ ledgerFilesRel
              <#> (\fileRel -> Path.resolve [journalDir] fileRel)

          for_ (difference foundFiles ledgerFilesAbs) $ \filePathAbs ->
            log $ withGraphics
              (foreground Yellow)
              ("Warning: \"" <> filePathAbs
                  <> "\" is not referenced in the journal")


    [Just command, Just ledgerFilePath, Nothing] -> do
      currentDir <- cwd
      result <- loadAndExec currentDir [command, ledgerFilePath]

      case result of
        Ok output -> if length output > 0
          then log output
          else pure unit
        Error message -> errorAndExit message

    _ -> log usageString


-- TODO: Use Monad transformers
-- resultT = ExceptT <<< toEither
-- unResultT = unExceptT >>> either Error Ok
-- main = do
--   result <- runResultT $ join $ map resultT $
--     loadAndExec <$> lift cwd <*> (resultT <<< parseArguments =<< lift argv)
--   case result of
--     Ok output -> log output
--     Error message -> error message
