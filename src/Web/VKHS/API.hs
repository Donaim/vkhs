module Web.VKHS.API
    ( api
    , envcall
    )  where

import Control.Monad
import Control.Monad.Trans
import Control.Monad.Writer
import Control.Monad.Error

import Data.Label
import qualified Data.ByteString.UTF8 as U
import qualified Data.ByteString.Char8 as BS

import Network.Curlhs.Core

import Network.Protocol.Http
import Network.Protocol.Uri
import Network.Protocol.Uri.Query

import Text.Printf

import Web.VKHS.Types
import Web.VKHS.Curl

envcall :: String -> Env CallEnv
envcall at = mkEnv (CallEnv at)

-- | Invoke the request. Return answer (normally, string representation of
-- JSON data). See documentation:
--
-- <http://vk.com/developers.php?oid=-1&p=%D0%9E%D0%BF%D0%B8%D1%81%D0%B0%D0%BD%D0%B8%D0%B5_%D0%BC%D0%B5%D1%82%D0%BE%D0%B4%D0%BE%D0%B2_API>
api :: Env CallEnv
    -- ^ the VKHS environment
    -> String
    -- ^ API method name
    -> [(String, String)]
    -- ^ API method parameters (name-value pairs)
    -> IO (Either String String)
api e mn mp =
  let uri = showUri $ (\f -> f $ toUri $ printf "https://api.vk.com/method/%s" mn) $
              set query $ bw params (("access_token",(access_token . sub) e):mp)
  in runErrorT $ do
    r <- ErrorT $ do
      vk_curl e (tell [CURLOPT_URL $ U.fromString uri])
    (_,b) <- ErrorT $ return $ parseResponse r
    return b

