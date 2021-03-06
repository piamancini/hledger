#!/usr/bin/env stack
{- stack runghc --verbosity info
   --package hledger-lib
   --package hledger
   --package Chart
   --package Chart-diagrams
   --package cmdargs
   --package colour
   --package data-default
   --package safe
-}
{-

hledger-chart

Generates primitive pie charts, based on the old hledger-chart package.
Supposed to show only balances of one sign, but this might be broke.

Copyright (c) 2007-2017 Simon Michael <simon@joyful.com>
Released under GPL version 3 or later.

-}

{-# LANGUAGE OverloadedStrings #-}

import Control.Monad
import Data.Colour
import Data.Colour.Names
import Data.Colour.RGBSpace
import Data.Colour.RGBSpace.HSL (hsl)
import Data.Colour.SRGB.Linear (rgb)
import Data.Default
import Data.List
import Data.Maybe
import Data.Ord
import qualified Data.Text as T
import Data.Tree
import Graphics.Rendering.Chart
import Graphics.Rendering.Chart.Backend.Diagrams
import Safe
import System.Console.CmdArgs hiding (def)
import System.Console.CmdArgs.Explicit
import System.Exit
import Text.Printf

import Hledger
import Hledger.Cli hiding (progname,progversion)

-- options

-- progname    = "hledger-chart"
-- progversion = progname ++ " dev"

defchartoutput   = "hledger.svg"
defchartitems    = 10
defchartsize     = "600x400"

chartmode = (defCommandMode ["hledger-chart"]) {
   modeArgs = ([], Just $ argsFlag "[PATTERNS] --add-posting \"ACCT  AMTEXPR\" ...")
  ,modeHelp = "generate a pie chart image for the top account balances (of one sign only)"
  ,modeHelpSuffix=[]
  ,modeGroupFlags = Group {
     groupNamed = [generalflagsgroup1]
    ,groupUnnamed = [
         flagReq ["chart-output","o"]  (\s opts -> Right $ setopt "chart-output" s opts) "IMGFILE" ("output filename (default: "++defchartoutput++")")
        ,flagReq ["chart-items"]  (\s opts -> Right $ setopt "chart-items" s opts) "N" ("number of accounts to show (default: "++show defchartitems++")")
        ,flagReq ["chart-size"]  (\s opts -> Right $ setopt "chart-size" s opts) "WIDTHxHEIGHT" ("image size (default: "++defchartsize++")")
        ]
    ,groupHidden = []
    }
  }

-- hledger-chart options, used in hledger-chart and above
data ChartOpts = ChartOpts {
     chart_output_ :: FilePath
    ,chart_items_ :: Int
    ,chart_size_ :: String
    ,cliopts_   :: CliOpts
 } deriving (Show)

defchartopts = ChartOpts
    def
    def
    def
    defcliopts

-- instance Default CliOpts where def = defcliopts

toChartOpts :: RawOpts -> IO ChartOpts
toChartOpts rawopts = do
  cliopts <- rawOptsToCliOpts rawopts
  return defchartopts {
              chart_output_ = fromMaybe defchartoutput $ maybestringopt "debug-chart" rawopts
             ,chart_items_ = fromMaybe defchartitems $ maybeintopt "debug-items" rawopts
             ,chart_size_ = fromMaybe defchartsize $ maybestringopt "debug-size" rawopts
             ,cliopts_   = cliopts
             }

checkChartOpts :: ChartOpts -> IO ChartOpts
checkChartOpts opts = do
  (checkCliOpts $ cliopts_ opts) `seq` return opts

getHledgerChartOpts :: IO ChartOpts
getHledgerChartOpts = processArgs chartmode >>= return . decodeRawOpts >>= toChartOpts >>= checkChartOpts

-- main

main :: IO ()
main = do
  chopts <- getHledgerChartOpts
  d <- getCurrentDay
  j <- defaultJournal
  let ropts = (reportopts_ $ cliopts_ chopts)
  let balreport = singleBalanceReport ropts (queryFromOpts d ropts) j
  let go -- | "--help" `elem` (rawopts_ $ cliopts_ chopts)    = putStr (showModeHelp chartmode) >> exitSuccess
         -- | "--version" `elem` (rawopts_ $ cliopts_ chopts) = putStrLn progversion >> exitSuccess
         | otherwise                                       = withJournalAndChartOptsDo chopts (writeChart balreport)
  go

-- copied from hledger-web
withJournalAndChartOptsDo :: ChartOpts -> (ChartOpts -> Journal -> IO ()) -> IO ()
withJournalAndChartOptsDo opts cmd = do
  f <- head `fmap` journalFilePathFromOpts (cliopts_ opts)
  readJournalFile Nothing Nothing True f >>=
   either error' (cmd opts . journalApplyAliases (aliasesFromOpts $ cliopts_ opts))

-- | Generate an image with the pie chart and write it to a file
writeChart :: BalanceReport -> ChartOpts -> Journal -> IO ()
writeChart balreport opts j = do
  d <- getCurrentDay
  if null $ jtxns j
   then putStrLn "This journal has no transactions, can't make a chart." >> exitFailure
   else do
     let chart = genPie opts balreport
     let fileoptions = def -- FileOptions (fromIntegral w, fromIntegral h) SVG loadSansSerifFonts
     renderableToFile fileoptions filename (toRenderable chart)
     return ()
      where
        filename = chart_output_ opts
        (w,h) = parseSize $ chart_size_ opts
        ropts = reportopts_ $ cliopts_ opts

-- | Parse image size from a command-line option
parseSize :: String -> (Int,Int)
parseSize str = (read w, read h)
    where
    x = fromMaybe (error' "Size should be in WIDTHxHEIGHT format") $ findIndex (=='x') str
    (w,_:h) = splitAt x str

-- | Generate pie chart
genPie :: ChartOpts -> BalanceReport -> PieLayout
genPie opts (items, total) = def { _pie_background = solidFillStyle $ opaque $ white
                                 , _pie_plot = pie_chart }
    where
      pie_chart = def { _pie_data = map (uncurry accountPieItem) chartitems
                      , _pie_start_angle = (-90)
                      , _pie_colors = mkColours hue
                      , _pie_label_style = def{_font_size=12}
                      }
      chartitems = dbg1 "chart" $ top num samesignitems :: [(AccountName, Double)]
      (samesignitems, sign) = sameSignNonZero items
      top n t = topn ++ [other]
          where
            (topn,rest) = splitAt n $ reverse $ sortBy (comparing snd) t
            other = ("other", sum $ map snd rest)
      num = chart_items_ opts
      hue = if sign > 0 then red else green where (red, green) = (0, 110)
      copts = cliopts_ opts
      ropts = reportopts_ copts

-- | Select the nonzero items with same sign as the first, and make
-- them positive. Also return a 1 or -1 corresponding to the original sign.
sameSignNonZero :: [BalanceReportItem] -> ([(AccountName, Double)], Int)
sameSignNonZero is
 | null nzs = ([], 1)
 | otherwise = (map pos $ filter (test.fourth4) nzs, sign)
 where
   nzs = filter ((/=0).fourth4) is
   pos (acct,_,_,Mixed as) = (acct, abs $ read $ show $ maybe 0 aquantity $ headMay as)
   sign = if fourth4 (head nzs) >= 0 then 1 else (-1)
   test = if sign > 0 then (>0) else (<0)

-- | Convert all quantities of MixedAccount to a single commodity
-- amountValue :: MixedAmount -> Double
-- amountValue = quantity . mixedAmountWithCommodity unknown

-- | Generate a tree of account names together with their balances.
--   The balance of account is decremented by the balance of its subaccounts
--   which are drawn on the chart.
-- balances :: Tree Account -> Tree (AccountName, Double)
-- balances (Node rootAcc subAccs) = Node newroot newsubs
--     where
--       newroot = (aname rootAcc,
--                  amountValue $
--                  aibalance rootAcc - (sum . map (aibalance . root)) subAccs)
--       newsubs = map balances subAccs

-- | Build a single pie chart item
accountPieItem :: AccountName -> Double -> PieItem
accountPieItem accname balance = PieItem (T.unpack accname) offset balance where offset = 0

-- | Generate an infinite color list suitable for charts.
mkColours :: Double -> [AlphaColour Double]
mkColours hue = cycle $ [opaque $ rgbToColour $ hsl h s l | (h,s,l) <- liftM3 (,,)
                         [hue] [0.7] [0.1,0.2..0.7] ]

rgbToColour :: (Fractional a) => RGB a -> Colour a
rgbToColour (RGB r g b) = rgb r g b
