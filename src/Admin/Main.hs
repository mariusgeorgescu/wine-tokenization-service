module Main where

import Data.Aeson (encode, toJSON)
import Data.ByteString.Lazy qualified as B
import GeniusYield.GYConfig (
    GYCoreConfig (cfgNetworkId),
    withCfgProviders,
 )
import GeniusYield.TxBuilder (queryBalance)
import GeniusYield.Types (
    GYLogNamespace,
    addressFromPaymentKeyHash,
    lovelaceOf,
    paymentKeyHash,
    paymentVerificationKey,
    pubKeyHash,
    pubKeyHashToPlutus,
    readPaymentSigningKey,
    signGYTxBody,
    txIdToApi,
    txOutRefFromApiTxIdIx,
    validatorToScript,
    valueSplitAda,
    wordToApiIx,
 )
import Offchain.Context (
    ProviderCtx (ProviderCtx),
    WineAdminContext (WineAdminContext),
    runQuery,
    runTx',
 )
import Offchain.OffchainUtils (
    decodeConfigEnvOrFile,
    yellowColorString,
 )
import Offchain.Operations (addRefScriptSkeleton)
import Offchain.Transactions (submitTxAndWaitForConfirmation)
import Offchain.Validators (
    mkWineScriptGY,
    writeWineContractBlueprint,
 )
import Parameters (adminConfig, atlasCoreConfig, blueprintFile, validatorFile)
import System.Environment (getArgs)
import Text.Printf qualified as Printf
import Text.Read qualified as Text

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["deploy-validator", privKeyFile] -> do
            putStrLn $ yellowColorString "Reading atlas configuration (env or file) ..."
            atlasConfig <- decodeConfigEnvOrFile @GYCoreConfig "ATLAS_CONFIG_JSON" atlasCoreConfig

            putStrLn $ yellowColorString $ "Reading signing key file from " <> privKeyFile
            signKey <- readPaymentSigningKey privKeyFile

            putStrLn $ yellowColorString $ "Write validator file:" <> validatorFile
            let adminPkh = pubKeyHashToPlutus $ pubKeyHash (paymentVerificationKey signKey)
            let validator = mkWineScriptGY adminPkh

            putStrLn $ yellowColorString $ "Write the contract blueprint:" <> blueprintFile
            writeWineContractBlueprint adminPkh

            putStrLn $ yellowColorString "Loading Providers ..."
            withCfgProviders atlasConfig (Text.read @GYLogNamespace "wine-server") $ \providers -> do
                let addminAddr = addressFromPaymentKeyHash (cfgNetworkId atlasConfig) (paymentKeyHash . paymentVerificationKey $ signKey)
                putStrLn $ yellowColorString $ Printf.printf "Admin address = %s" addminAddr
                let pCtx = ProviderCtx atlasConfig providers
                balance <- runQuery pCtx $ queryBalance addminAddr
                let (lovelaces, _) = valueSplitAda balance
                let ada = lovelaceOf lovelaces
                putStrLn $ yellowColorString $ Printf.printf "Admin lovelaces balance = %s" (show ada)

                putStrLn $ yellowColorString $ "Deploying reference script, with admin:" <> show adminPkh
                txBody <- runTx' pCtx [addminAddr] addminAddr Nothing (addRefScriptSkeleton (validatorToScript validator))
                let signedTx = signGYTxBody txBody [signKey]
                gyTxId <- submitTxAndWaitForConfirmation False providers signedTx
                let txId = txIdToApi gyTxId
                let txOutRef = txOutRefFromApiTxIdIx txId (wordToApiIx 0)
                B.writeFile adminConfig (encode . toJSON $ WineAdminContext txOutRef signKey)

                putStrLn $ yellowColorString $ "Write admin config file:" <> adminConfig
                return ()
        _ -> putStrLn "Usage: deploy-validator <private key file path>"