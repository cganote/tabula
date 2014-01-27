-- Redis destination for tabula
{-# LANGUAGE LambdaCase #-}
module Tabula.Destination.Redis (
      redisDestination
    , defaultConnectInfo
    , ConnectInfo(..)
  ) where
  import Control.Exception (handleJust)
  import Control.Monad (void)
  import Control.Monad.IO.Class

  import Data.Aeson
  import qualified Data.ByteString.Char8 as B
  import qualified Data.ByteString.Lazy as L
  import Data.Conduit
  import qualified Data.Conduit.List as DCL
  import Data.Maybe (catMaybes)
  import Database.Redis hiding (decode)

  import Tabula.Destination
  import Tabula.Record (Record)

  redisDestination :: ConnectInfo -> String -> Destination
  redisDestination connInfo project = Destination {
      recordSink = redisSink connInfo (B.pack project)
    , getLastRecord = lastRecord connInfo (B.pack project)
    , recordSource = redisSource connInfo (B.pack project)
  }

  redisSink :: ConnectInfo -> B.ByteString -> Sink Record (ResourceT IO) ()
  redisSink connInfo project = bracketP
      (connect connInfo)
      (\conn -> void $ runRedis conn quit)
      (\conn -> loop conn)
    where 
      loop conn = awaitForever $ \rec -> let 
          recS = B.concat . L.toChunks $ encode rec
        in liftIO . ensureConnection . runRedis conn $ do
             void $ lpush project [recS]
      ensureConnection = handleJust (\case 
          ConnectionLost -> Just ()
          _ -> Nothing)
        (\_ -> return ())

  -- Redis source. At the moment, just get all posts (should probably chunk nicely!)
  redisSource :: ConnectInfo -> B.ByteString -> Source (ResourceT IO) Record
  redisSource connInfo project = bracketP
      (connect connInfo)
      (\conn -> void $ runRedis conn quit)
      (\conn -> stream conn)
    where
      stream conn = do
        results <- liftIO . runRedis conn $ lrange project 0 (-1)
        case results of
          Right bs -> DCL.sourceList . catMaybes . map (decode . L.fromStrict) $ bs
          Left _ -> return ()

  lastRecord :: ConnectInfo -> B.ByteString -> IO (Maybe Record)
  lastRecord connInfo project = do
    conn <- connect connInfo
    thing <- runRedis conn $ lindex project 0
    case thing of
      Right (Just bs) -> return . decode . L.fromStrict $ bs
      _ -> return Nothing