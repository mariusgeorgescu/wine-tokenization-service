{-# LANGUAGE NoImplicitPrelude #-}

module IPFS where

import App (AppM (..))
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Network.IPFS as IPFS
import qualified Network.IPFS.CID.Types as CID
import qualified Network.IPFS.Client as IPFSC
import qualified Network.IPFS.File.Types as File
import Offchain.Interactions (TokenData (..))
import RIO
import qualified RIO.ByteString.Lazy as Lazy
import qualified RIO.Text as Text
import System.IO.Error (userError)


-- Remote IPFS helpers operating in AppM
addToIPFS :: BS.ByteString -> AppM (Either Text Text)
addToIPFS raw = AppM $ do
  res <- IPFS.runRemote (IPFSC.add raw)
  pure $ case res of
    Right cidVal -> Right (Text.pack (show cidVal))
    Left err -> Left (Text.pack (show err))

catFromIPFS :: Text -> AppM (Either Text Text)
catFromIPFS cidTxt = AppM $ do
  let cidStr = Text.unpack cidTxt
  let cidVal = fromString cidStr :: CID.CID
  res <- IPFS.runRemote (IPFSC.cat cidVal)
  pure $ case res of
    Right (File.Serialized contents) -> Right (decodeUtf8Lenient $ Lazy.toStrict contents)
    Left err -> Left (Text.pack (show err))

addByteStringToIPFS :: BS.ByteString -> AppM String
addByteStringToIPFS val = do
  r <- addToIPFS val
  case r of
    Right cid -> pure ("ipfs://" <> Text.unpack cid)
    Left e -> liftIO $ throwIO (userError (Text.unpack e))

addStringToIPFS :: String -> AppM String
addStringToIPFS val = addByteStringToIPFS (fromString val)

addTokenDataToIPFS :: TokenData -> AppM TokenData
addTokenDataToIPFS (TokenData i d s) = do
  infoLink <- addStringToIPFS i
  mdataLink <- mapM addStringToIPFS d
  minsLink <- mapM addStringToIPFS s
  pure (TokenData infoLink mdataLink minsLink)

getStringFromIPFS :: String -> AppM String
getStringFromIPFS str = do
  let cid = Text.pack (drop 7 str)
  r <- catFromIPFS cid
  case r of
    Right t -> pure (Text.unpack t)
    Left e -> liftIO $ throwIO (userError (Text.unpack e))

getTokenDataFromIPFS :: TokenData -> AppM TokenData
getTokenDataFromIPFS (TokenData i d s) = do
  info <- getStringFromIPFS i
  mdata <- mapM getStringFromIPFS d
  mins <- mapM getStringFromIPFS s
  pure (TokenData info mdata mins)
