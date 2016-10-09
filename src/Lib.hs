{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}

module Lib
  ( startApp
  ) where

import Protolude

import Network.Wai.Handler.Warp
       (Port, Settings, defaultSettings, runSettings, setBeforeMainLoop,
        setPort)
import qualified Network.Wai.Middleware.RequestLogger as RL
import Options.Applicative
       (ParserInfo, auto, eitherReader, execParser, fullDesc, header,
        help, helper, info, long, metavar, option, progDesc, value)
import qualified Prometheus as Prom
import qualified Prometheus.Metric.GHC as Prom
import Servant (serve)
import Text.PrettyPrint.Leijen.Text (int, text)

import API (API, server)
import Instrument (instrumentApp, requestDuration)
import qualified Logging as Log

-- | Configuration for the application.
data Config = Config
  { port :: Port
  , accessLogs :: AccessLogs
  } deriving (Show)

data AccessLogs
  = Disabled
  | Enabled
  | DevMode
  deriving (Eq, Show)

startApp :: IO ()
startApp = runApp =<< execParser options

options :: ParserInfo Config
options = info (helper <*> parser) description
  where
    parser =
      Config <$>
      option auto (fold [long "port", metavar "PORT", help "Port to listen on"]) <*>
      option
        (eitherReader parseAccessLogs)
        (fold
           [long "access-logs", help "How to log HTTP access", value Disabled])
    parseAccessLogs "none" = pure Disabled
    parseAccessLogs "basic" = pure Enabled
    parseAccessLogs "dev" = pure DevMode
    parseAccessLogs _ = throwError "One of 'none', 'basic', or 'dev'"
    description =
      fold
        [ fullDesc
        , progDesc "Simple web API server"
        , header "hello-prometheus-haskell - Demo of Prometheus with Haskell"
        ]

runApp :: Config -> IO ()
runApp config@Config {..} = do
  requests <- Prom.registerIO requestDuration
  void $ Prom.register Prom.ghcMetrics
  runSettings settings (middleware requests)
  where
    settings = warpSettings config
    middleware r = logging . instrumentApp r "hello_world" $ app
    logging =
      case accessLogs of
        Disabled -> identity
        Enabled -> RL.logStdout
        DevMode -> RL.logStdoutDev
    app = serve (Proxy :: Proxy API) server

-- | Generate warp settings from config
--
-- Serve from a port and print out where we're serving from.
warpSettings :: Config -> Settings
warpSettings Config {..} =
  setBeforeMainLoop (Log.withLogging printPort) (setPort port defaultSettings)
  where
    printPort = Log.info (text "Listening on :" `mappend` int port)
