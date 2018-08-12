{-| Definitions of basic API types such as Response and Error, definitions of
 - various API-caller functions -}

{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Web.VKHS.API.Base where

import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.ByteString.Char8 as BS

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.Aeson.Encode.Pretty as Aeson

import Web.VKHS.Imports
import Web.VKHS.Types
import Web.VKHS.Client hiding (Response(..))
import Web.VKHS.Monad
import Web.VKHS.Error

import Debug.Trace

-- | VK Response representation
data Response a = Response {
    resp_json :: JSON
    -- ^ Original JSON representation of the respone, as received from the VK
  , resp_data :: (a,Bool)
    -- ^ Haskell ADT representation of the response
  } deriving (Show, Functor, Data, Typeable)

emptyResponse :: (Monoid a) => Response a
emptyResponse = Response (JSON $ Aeson.object []) (mempty,True)

parseJSON_obj_error :: String -> Aeson.Value -> Aeson.Parser a
parseJSON_obj_error name o = fail $
  printf "parseJSON: %s expects object, got %s" (show name) (show o)

instance (FromJSON a) => FromJSON (Response a) where
  parseJSON j = Aeson.withObject "Response" (\o ->
    Response
      <$> pure (JSON j)
      <*> (((,) <$> (o .: "error") <*> pure False) <|> ((,) <$> (o .: "response") <*> pure True))
      ) j

type Cache = Map (MethodName,MethodArgs) (JSON,Time)

cacheQuery :: DiffTime -> MethodName -> MethodArgs -> Time -> Cache -> Maybe JSON
cacheQuery maxage mname margs time c =
  case Map.lookup (mname,margs) c of
    Just (json,birth) ->
      case time `diffTime` birth > maxage of
        True -> Nothing {- record is too old -}
        False -> Just json
    Nothing -> Nothing

cacheAdd :: MethodName -> MethodArgs -> JSON -> Time -> Cache -> Cache
cacheAdd mname margs json time = Map.insert (mname,margs) (json,time)

cacheFilter :: DiffTime -> Time -> Cache -> Cache
cacheFilter maxage now = Map.filter (\(_,t) -> (now`diffTime`t) < maxage)

cacheSave :: FilePath -> Cache -> IO ()
cacheSave fp c = writeFile fp (show c)

cacheLoad :: FilePath -> IO (Maybe Cache)
cacheLoad fp =
  let
    safeReadFile fn = do
      liftIO $ Web.VKHS.Imports.catch (Just <$> readFile fn) (\(e :: SomeException) -> return Nothing)
  in
  (readMaybe =<<) <$> safeReadFile fp

-- | State of the API engine
data APIState = APIState {
    api_access_token :: String
  , api_state_cache :: Cache
  } deriving (Show)

defaultState :: APIState
defaultState = APIState {
    api_access_token = ""
  , api_state_cache = Map.empty
  }

class ToGenericOptions s => ToAPIState s where
  toAPIState :: s -> APIState
  modifyAPIState :: (APIState -> APIState) -> (s -> s)

-- | Class of monads able to run VK API calls. @m@ - the monad itself, @x@ -
-- type of early error, @s@ - type of state (see alse @ToAPIState@)
class (MonadIO (m (R m x)), MonadClient (m (R m x)) s, ToAPIState s, MonadVK (m (R m x)) (R m x)) =>
  MonadAPI m x s | m -> s


-- | Short alias for the coroutine monad
type API m x a = m (R m x) a

-- | Perform API call
api :: (MonadAPI m x s) => MethodName -> MethodArgs -> API m x JSON
api mname margs = raise (ExecuteAPI (mname,margs))

-- | Upload File to server
upload :: (MonadAPI m x s) => HRef -> FilePath -> API m x UploadRecord
upload href filepath = raise (UploadFile (href,filepath))

-- | Ask superviser to re-login
login :: (MonadAPI m x s) => API m x AccessToken
login = raise APILogin

-- | Request the superviser to log @text@
message :: (MonadAPI m x s) => Verbosity -> Text -> API m x ()
message verb text = raise (APIMessage verb text)

debug :: (MonadAPI m x s) => Text -> API m x ()
debug = message Debug

api1 :: forall m x a s . (Aeson.FromJSON a, MonadAPI m x s)
    => MethodName -- ^ API method name
    -> MethodArgs -- ^ API method arguments
    -> API m x a
api1 mname margs = do
  json <- api mname margs
  case parseJSON json of
    (Left e1) -> do
      terminate $ APIFailed $ APIInvalidJSON mname json e1
    (Right (Response _ (a,_))) -> do
      return a

api2 :: forall m x a b s . (Aeson.FromJSON a, Aeson.FromJSON b, MonadAPI m x s)
    => MethodName -- ^ API method name
    -> MethodArgs -- ^ API method arguments
    -> API m x (Either a b)
api2 mname margs = do
  json <- api mname margs
  case (parseJSON json, parseJSON json) of
    (Left e1, Left e2) -> do
      terminate $ APIFailed $ APIInvalidJSON mname json (e1 <> ";" <> e2)
    (Right (Response _ (a,_)), _) -> do
      return (Left a)
    (_, Right (Response _ (b,_))) -> do
      return (Right b)

