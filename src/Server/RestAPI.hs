{-# LANGUAGE DeriveAnyClass #-}

module RestAPI where

import Control.Monad.Except

import Control.Exception (throw)
import Control.Exception.Extra (try)
import Control.Lens ((&), (.~), (?~))
import RIO (ask, runRIO, liftIO)
import Data.ByteString.Lazy qualified as BS
import Data.List (lookup)
import Data.Swagger
import Data.Text.Encoding qualified
import GeniusYield.Types hiding (description, title)
import IPFS
import Network.HTTP.Types qualified as HttpTypes
import Network.HTTP.Types.Header
import Network.Wai
import Network.Wai.Middleware.Cors
import Offchain.Context (WineAdminContext (..), WineOffchainContext (..), runQuery)
import Offchain.Interactions (
    TokenData,
    TokenMeta,
    WineAction (..),
    WineInteraction (WineInteraction),
    WineTokenDT (Batch, Bottle),
    fromWineToken,
    getTokenData,
    updateTokenData,
 )
import Offchain.Operations
import Offchain.Transactions (runWineTx)

import Data.String
import Network.Wai.Middleware.Servant.Options (provideOptions)
import RIO.Text qualified as T
import Servant
import Servant.Swagger
import Servant.Swagger.UI

import App (AppEnv(..), AppM(..))

newtype BinaryData = BinaryData {unBinaryData :: BS.ByteString}
    deriving (Show, Eq, Generic)

-- For Swagger
instance ToSchema BinaryData where
    declareNamedSchema _ = pure $ NamedSchema (Just "BinaryData") binarySchema

-- For Servant: allow parsing from application/octet-stream
instance MimeUnrender OctetStream BinaryData where
    mimeUnrender _ = Right . BinaryData

-- You may also want to allow encoding (e.g., if responding with binary)
instance MimeRender OctetStream BinaryData where
    mimeRender _ = unBinaryData

newtype User = User
    { user :: T.Text
    }
    deriving (Eq, Show)

data TxResp = TxResp
    { txId :: GYTxId
    , tokenRefId :: Maybe GYAssetClass
    }
    deriving (Generic, FromJSON, ToJSON, ToSchema)

mkTxResp :: (GYTxId, Maybe GYAssetClass) -> TxResp
mkTxResp = uncurry TxResp

data WineBatchDTO = WineBatchDTO
    { batch_meta :: TokenMeta
    , batch_data :: TokenData
    , batch_quantity :: (Integer, Integer)
    }
    deriving (Generic, FromJSON, ToJSON, ToSchema)

data WineBottleDTO = WineBottleDTO
    { bottle_meta :: TokenMeta
    , bottle_data :: TokenData
    , bottle_batch_id :: GYAssetClass
    }
    deriving (Generic, FromJSON, ToJSON, ToSchema)

type WineLookupAPI =
    Summary "Retrieve wine NFT details"
        :> Description "Fetches Wine NFT information based on the given token ID."
        :> "wine"
        :> Capture "Token Id" GYAssetClass
        :> Get '[JSON] WineTokenDT
type WineTxAPI =
    "tx"
        :> Capture "wait 1 conf?" Bool
        :> ( Summary "Mint a new batch NFT"
                :> Description "Creates a new batch NFT with metadata and initial quantity."
                :> "mint-batch"
                :> ReqBody '[JSON] WineBatchDTO
                :> Post '[JSON] TxResp
                :<|> Summary "Mint a new bottle NFT"
                    :> Description "Creates a new bottle NFT under an existing batch."
                    :> "mint-bottle"
                    :> ReqBody '[JSON] WineBottleDTO
                    :> Post '[JSON] TxResp
                :<|> Summary "Update an existing batch NFT"
                    :> Description "Modifies metadata and token data of a batch NFT."
                    :> "update-batch"
                    :> Capture "Batch Ref NFT id" GYAssetClass
                    :> ReqBody '[JSON] WineBatchDTO
                    :> Put '[JSON] TxResp
                :<|> Summary "Update an existing bottle NFT"
                    :> Description "Modifies metadata and token data of a bottle NFT."
                    :> "update-bottle"
                    :> Capture "Bottle ref NFT id" GYAssetClass
                    :> ReqBody '[JSON] WineBottleDTO
                    :> Put '[JSON] TxResp
                :<|> Summary "Burn a user-owned wine NFT"
                    :> Description "Deletes an NFT that belongs to a user."
                    :> "burn-user"
                    :> Capture "User NFT id" GYAssetClass
                    :> Delete '[JSON] TxResp
                :<|> Summary "Burn a reference wine NFT"
                    :> Description "Deletes a reference NFT."
                    :> "burn-ref"
                    :> Capture "Ref NFT id" GYAssetClass
                    :> Delete '[JSON] TxResp
           )

type IpfsAPI =
    Summary "Add to IPFS"
        :> Description "Add to IPFS"
        :> "add"
        :> ReqBody '[OctetStream] BinaryData
        :> Post '[JSON] String

type WineAPI = (WineTxAPI :<|> WineLookupAPI :<|> IpfsAPI)
type WineAPIPrivate = BasicAuth "user-realm" User :> (WineTxAPI :<|> WineLookupAPI :<|> IpfsAPI)

type WineREST =
    SwaggerSchemaUI "swagger-ui" "swagger-api.json"
        :<|> WineAPIPrivate

wineTxAPI :: Proxy WineTxAPI
wineTxAPI = Proxy

wineAPI :: Proxy WineAPI
wineAPI = Proxy

wineAPIwithSwagger :: Proxy WineREST
wineAPIwithSwagger = Proxy

apiSwagger :: Swagger
apiSwagger =
    toSwagger wineAPI
        & info . title .~ "Wine Tokenization Service"
        & info . version .~ "1.0"
        & info . description ?~ "This is an API for tokenizing batches and bottles of wine"
        & Data.Swagger.info
            . Data.Swagger.license
            ?~ "GPL-3.0 license"
        & host .~ Nothing

wineServer :: ServerT WineREST AppM
wineServer =
    swaggerSchemaUIServerT apiSwagger
        :<|> const
            ( txServer
                :<|> handleGetNFT
                :<|> handleAddIPFS
            )

handleAddIPFS :: BinaryData -> AppM String
handleAddIPFS (BinaryData bs) = addByteStringToIPFS bs

txServer :: ServerT WineTxAPI AppM
txServer wait =
    handleMintBatchTx wait
        :<|> handleMintBottleTx wait
        :<|> handleUpdateBatchTx wait
        :<|> handleUpdateBottleTx wait
        :<|> handleBurnUserTx wait
        :<|> handleBurnRefTx wait

handleMintBatchTx :: Bool -> WineBatchDTO -> AppM TxResp
handleMintBatchTx wait (WineBatchDTO i d s) = do
    d' <- addTokenDataToIPFS d
    AppEnv{aeWineOffchainCtx=ctx} <- ask
    liftIO $ mkTxResp <$> runWineTx wait ctx (WineInteraction MintBatch (Just (Batch i d' s)))

handleMintBottleTx :: Bool -> WineBottleDTO -> AppM TxResp
handleMintBottleTx wait (WineBottleDTO i d s) = do
    d' <- addTokenDataToIPFS d
    AppEnv{aeWineOffchainCtx=ctx} <- ask
    liftIO $ mkTxResp <$> runWineTx wait ctx (WineInteraction MintBottle (Just (Bottle i d' s)))

handleUpdateBatchTx :: Bool -> GYAssetClass -> WineBatchDTO -> AppM TxResp
handleUpdateBatchTx wait batchId (WineBatchDTO i d s) = do
    d' <- addTokenDataToIPFS d
    AppEnv{aeWineOffchainCtx=ctx} <- ask
    liftIO $ mkTxResp <$> runWineTx wait ctx (WineInteraction (UpdateBatch batchId) (Just (Batch i d' s)))

handleUpdateBottleTx :: Bool -> GYAssetClass -> WineBottleDTO -> AppM TxResp
handleUpdateBottleTx wait bottleId (WineBottleDTO i d s) = do
    d' <- addTokenDataToIPFS d
    AppEnv{aeWineOffchainCtx=ctx} <- ask
    liftIO $ mkTxResp <$> runWineTx wait ctx (WineInteraction (UpdateBottle bottleId) (Just (Bottle i d' s)))

handleBurnUserTx :: Bool -> GYAssetClass -> AppM TxResp
handleBurnUserTx wait tokenId = do
    AppEnv{aeWineOffchainCtx=ctx} <- ask
    liftIO $ mkTxResp <$> runWineTx wait ctx (WineInteraction (BurnUserToken tokenId) Nothing)

handleBurnRefTx :: Bool -> GYAssetClass -> AppM TxResp
handleBurnRefTx wait tokenId = do
    AppEnv{aeWineOffchainCtx=ctx} <- ask
    liftIO $ mkTxResp <$> runWineTx wait ctx (WineInteraction (BurnRefToken tokenId) Nothing)

handleGetNFT :: GYAssetClass -> AppM WineTokenDT
handleGetNFT tokenId = do
    AppEnv{aeWineOffchainCtx=(WineOffchainContext (WineAdminContext{..}) providetCtx)} <- ask
    w <- liftIO $ runQuery providetCtx $ getWineTokenFromValidator (assetClassToPlutus tokenId) wineValidatorRef
    case w of
        Left err -> liftIO $ throw $ err400{errBody = fromString err}
        Right wt -> do
            let wtdt = fromWineToken wt
            let d = getTokenData wtdt
            d' <- getTokenDataFromIPFS d
            pure $ updateTokenData wtdt d'

restAPIapp :: Text -> Text -> AppEnv -> Application
restAPIapp usr pass env =
    cors
        ( \req ->
            let
                originHeader = lookup hOrigin (requestHeaders req)
             in
                case originHeader of
                    Just o ->
                        Just
                            simpleCorsResourcePolicy
                                { corsOrigins = Just ([o], True) -- Reflect request's Origin dynamically
                                , corsMethods = ["GET", "POST", "PUT", "OPTIONS", "DELETE"]
                                , corsRequestHeaders = simpleHeaders <> [HttpTypes.hAuthorization]
                                , corsExposedHeaders = Just $ simpleHeaders <> [HttpTypes.hAuthorization]
                                , corsVaryOrigin = True
                                , corsRequireOrigin = False
                                , corsIgnoreFailures = False
                                }
                    Nothing -> Nothing -- If no origin set skips cors headers
        )
        $ provideOptions wineTxAPI
        $ serveWithContext wineAPIwithSwagger basicCtx
        $ hoistServerWithContext wineAPIwithSwagger (Proxy :: Proxy '[BasicAuthCheck User]) (nt env)
        $ wineServer
  where
    basicCtx = basicAuthServerContext usr pass

    nt :: AppEnv -> AppM a -> Servant.Handler a
    nt e (AppM action) = Servant.Handler $ ExceptT $ try $ runRIO e action

-- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
authCheck :: Text -> Text -> BasicAuthCheck User
authCheck usr pass =
    let checkk (BasicAuthData username password) =
            if Data.Text.Encoding.decodeUtf8 username == usr && Data.Text.Encoding.decodeUtf8 password == pass
                then return (Authorized (User usr))
                else return Unauthorized
     in BasicAuthCheck checkk

{- | We need to supply our handlers with the right Context. In this case,
Basic Authentication requires a Context Entry with the 'BasicAuthCheck' value
tagged with "foo-tag" This context is then supplied to 'server' and threaded
to the BasicAuth HasServer handlers.
-}
basicAuthServerContext :: Text -> Text -> Context (BasicAuthCheck User ': '[])
basicAuthServerContext usr pass = authCheck usr pass :. EmptyContext