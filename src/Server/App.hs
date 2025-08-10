{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}

module App
  ( AppEnv (..),
    AppM (..),
    mkAppEnv,
  )
where

import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
-- Local

import qualified Network.IPFS as IPFS
import Offchain.Context (WineOffchainContext)
import RIO
import Servant.Client (BaseUrl)
import qualified Servant.Client as Servant

data AppEnv = AppEnv
  { aeLogFunc :: !LogFunc,
    aeHttpManager :: !Manager,
    aeIpfsBaseUrl :: !BaseUrl,
    aeWineOffchainCtx :: !WineOffchainContext
  }

instance HasLogFunc AppEnv where
  logFuncL = lens aeLogFunc (\x y -> x {aeLogFunc = y})

newtype AppM a = AppM {unAppM :: RIO AppEnv a}
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader AppEnv)

mkAppEnv :: LogFunc -> BaseUrl -> WineOffchainContext -> IO AppEnv
mkAppEnv lf baseUrl wineCtx = do
  manager <- newManager tlsManagerSettings
  pure
    AppEnv
      { aeLogFunc = lf,
        aeHttpManager = manager,
        aeIpfsBaseUrl = baseUrl,
        aeWineOffchainCtx = wineCtx
      }

-- Provide MonadRemoteIPFS instance via RIO AppEnv
instance IPFS.MonadRemoteIPFS (RIO AppEnv) where
  runRemote :: Servant.ClientM a -> RIO AppEnv (Either Servant.ClientError a)
  runRemote query = do
    AppEnv {aeHttpManager, aeIpfsBaseUrl} <- ask
    liftIO $ Servant.runClientM query (Servant.mkClientEnv aeHttpManager aeIpfsBaseUrl)
