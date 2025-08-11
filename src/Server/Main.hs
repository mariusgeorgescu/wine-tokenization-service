{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use fewer imports" #-}
module Main where

import Control.Monad qualified

import Data.Aeson.Encode.Pretty
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text qualified
import GeniusYield.GYConfig
import GeniusYield.TxBuilder
import GeniusYield.Types
import Network.Wai.Handler.Warp (
    HostPreference,
    defaultSettings,
    runSettings,
    setHost,
    setPort,
 )
import Offchain.Context
import Offchain.OffchainUtils
import Parameters
import RIO (IsString (..))
import qualified RIO
import System.IO (stderr)
import RestAPI (apiSwagger, restAPIapp)
import Servant.Client (BaseUrl(..), Scheme(Http), parseBaseUrl)
import App (mkAppEnv)
import System.Environment
import Text.Printf qualified as Printf
import Text.Read (read)

getPortFromEnv :: IO Int
getPortFromEnv = do
    eport <- lookupEnv "PORT"
    case eport of
        Nothing -> return 8082
        Just p -> return (read p)

main :: IO ()
main = do
    args <- getArgs
    let (usr, pass) = case args of
            [x, y] -> (Data.Text.pack x, Data.Text.pack y)
            _ -> ("cardano" :: Text, "lovelace" :: Text) -- Default user and password for Basic Auth
    putStrLn $ yellowColorString "Writing Swagger file ..."
    BL8.writeFile "swagger-api.json" (encodePretty apiSwagger)
    putStrLn $ yellowColorString "Reading atlas configuration (env or file) ..."
    atlasConfig <- decodeConfigEnvOrFile @GYCoreConfig "ATLAS_CONFIG_JSON" atlasCoreConfig
    putStrLn $ yellowColorString "Reading admin configuration (env or file) ..."
    adminContext <- decodeConfigEnvOrFile @WineAdminContext "ADMIN_CONTEXT_JSON" adminConfig
    putStrLn $ yellowColorString "Loading Providers ..."
    withCfgProviders atlasConfig (read @GYLogNamespace "wine-server") $ \providers -> do
        let addminAddr = addressFromPaymentKeyHash (cfgNetworkId atlasConfig) (paymentKeyHash . paymentVerificationKey . winePaymentSigningKey $ adminContext)
        putStrLn $ greenColorString $ Printf.printf "Admin address = %s" addminAddr
        let pCtx = ProviderCtx atlasConfig providers
        balance <- runQuery pCtx $ queryBalance addminAddr
        let (lovelaces, _) = valueSplitAda balance
        let ada = lovelaceOf lovelaces
        putStrLn $ greenColorString $ Printf.printf "Admin lovelaces balance = %s" (show ada)

        Control.Monad.when (ada < 1000) $ putStrLn $ yellowColorString "Balance is low ..."

        --- Server
        let wineOffchainContext = WineOffchainContext adminContext pCtx
        let host = "0.0.0.0"
        port <- getPortFromEnv
        putStrLn $ yellowColorString $ "Starting server at : http://" <> host <> ":" <> show port
        putStrLn $ greenColorString $ "Swagget-UI at : http://" <> host <> ":" <> show port <> "/swagger-ui"
        let settings = setHost (fromString host :: HostPreference) $ setPort port defaultSettings -- host and port customized for heroku
        -- IPFS Base URL from env, default to localhost:5001
        mipfs <- lookupEnv "IPFS_API_URL"
        baseUrl <- case mipfs of
          Just urlTxt -> parseBaseUrl urlTxt
          Nothing -> pure $ BaseUrl Http "127.0.0.1" 5001 ""
        -- Build AppEnv
        logOptions' <- RIO.logOptionsHandle stderr False
        let logOptions = RIO.setLogUseTime True $ RIO.setLogUseLoc True logOptions'
        RIO.withLogFunc logOptions $ \lf -> do
          env <- mkAppEnv lf baseUrl wineOffchainContext
          runSettings settings $ restAPIapp usr pass env
