{-# LANGUAGE CPP, OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module HsDev.Server.Base (
	initLog, runServer, Server, startServer, inServer,
	withCache, writeCache, readCache,

	module HsDev.Server.Types,
	module HsDev.Server.Message
	) where

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Data.Default
import qualified Data.Map as M
import Data.Maybe
import Data.String
import Data.Text (Text)
import qualified Data.Text as T (pack, unpack)
import System.Log.Simple hiding (Level(..), Message)
import qualified System.Log.Simple.Base as Log
import System.Directory (removeDirectoryRecursive, createDirectoryIfMissing)
import System.FilePath

import qualified Control.Concurrent.FiniteChan as F
import System.Directory.Paths (canonicalize)
import qualified System.Directory.Watcher as Watcher
import Text.Format ((~~), FormatBuild(..), (~%))

import qualified HsDev.Cache as Cache
import qualified HsDev.Cache.Structured as SC
import qualified HsDev.Client.Commands as Client
import HsDev.Database
import qualified HsDev.Database.Async as DB
import qualified HsDev.Database.Update as Update
import HsDev.Inspect (getDefines)
import HsDev.Tools.Ghc.Worker
import HsDev.Server.Types
import HsDev.Server.Message
import HsDev.Util

#if mingw32_HOST_OS
import System.Win32.FileMapping.NamePool
#endif

-- | Inits log chan and returns functions (print message, wait channel)
initLog :: ServerOpts -> IO SessionLog
initLog sopts = do
	msgs <- F.newChan
	l <- newLog (logCfg [("", Log.level_ . T.pack . serverLogLevel $ sopts)]) $ concat [
		[handler text console | not $ serverSilent sopts],
		[handler text (chaner msgs)],
		[handler text (file f) | f <- maybeToList (serverLog sopts)]]
	let
		listenLog = F.dupChan msgs >>= F.readChan
	return $ SessionLog l listenLog (stopLog l)

instance FormatBuild Log.Level where

-- | Run server
runServer :: ServerOpts -> ServerM IO () -> IO ()
runServer sopts act = bracket (initLog sopts) sessionLogWait $ \slog -> Watcher.withWatcher $ \watcher -> withLog (sessionLogger slog) $ do
	waitSem <- liftIO $ newQSem 0
	db <- liftIO $ DB.newAsync
	withCache sopts () $ \cdir -> do
		sendLog Log.Trace $ "Checking cache version in {}" ~~ cdir 
		ver <- liftIO $ Cache.readVersion $ cdir </> Cache.versionCache
		sendLog Log.Debug $ "Cache version: {}" ~~ strVersion ver
		unless (sameVersion (cutVersion version) (cutVersion ver)) $ ignoreIO $ do
			sendLog Log.Info $ "Cache version ({cache}) is incompatible with hsdev version ({hsdev}), removing cache ({dir})" ~~
				("cache" ~% strVersion ver) ~~
				("hsdev" ~% strVersion version) ~~
				("dir" ~% cdir)
			-- drop cache
			liftIO $ removeDirectoryRecursive cdir
		sendLog Log.Debug $ "Writing new cache version: {}" ~~ strVersion version
		liftIO $ createDirectoryIfMissing True cdir
		liftIO $ Cache.writeVersion $ cdir </> Cache.versionCache
	when (serverLoad sopts) $ withCache sopts () $ \cdir -> do
		sendLog Log.Info $ "Loading cache from {}" ~~ cdir
		dbCache <- liftA merge <$> liftIO (SC.load cdir)
		case dbCache of
			Left err -> sendLog Log.Error $ "Failed to load cache: {}" ~~ err
			Right dbCache' -> DB.update db (return dbCache')
#if mingw32_HOST_OS
	mmapPool <- Just <$> liftIO (createPool "hsdev")
#endif
	ghcw <- ghcWorker
	defs <- liftIO getDefines
	let
		session = Session
			db
			(writeCache sopts)
			(readCache sopts)
			slog
			watcher
#if mingw32_HOST_OS
			mmapPool
#endif
			ghcw
			(do
				withLog (sessionLogger slog) $ sendLog Log.Trace "stopping server"
				signalQSem waitSem)
			(waitQSem waitSem)
			defs
	_ <- liftIO $ forkIO $ Update.onEvent watcher $ \w e -> withSession session $
		void $ Client.runClient def $ Update.processEvent def w e
	liftIO $ runReaderT (runServerM act) session

type Server = Worker (ServerM IO)

startServer :: ServerOpts -> IO Server
startServer sopts = startWorker (runServer sopts) id id

inServer :: Server -> CommandOptions -> Command -> IO Result
inServer srv copts c = do
	c' <- canonicalize c
	inWorker srv (Client.runClient copts $ Client.runCommand c')

chaner :: F.Chan String -> Consumer Text
chaner ch = return $ F.putChan ch . T.unpack

-- | Perform action on cache
withCache :: Monad m => ServerOpts -> a -> (FilePath -> m a) -> m a
withCache sopts v onCache = case serverCache sopts of
	Nothing -> return v
	Just cdir -> onCache cdir

writeCache :: SessionMonad m => ServerOpts -> Database -> m ()
writeCache sopts db = withCache sopts () $ \cdir -> do
	sendLog Log.Info $ "writing cache to {}" ~~ cdir
	logIO "cache writing exception: " (sendLog Log.Error . fromString) $ do
		let
			sd = structurize db
		liftIO $ SC.dump cdir sd
		forM_ (M.keys (structuredPackageDbs sd)) $ \c -> sendLog Log.Debug ("cache write: cabal {}" ~~ show c)
		forM_ (M.keys (structuredProjects sd)) $ \p -> sendLog Log.Debug ("cache write: project {}" ~~ p)
		case allModules (structuredFiles sd) of
			[] -> return ()
			ms -> sendLog Log.Debug $ "cache write: {} files" ~~ length ms
	sendLog Log.Info $ "cache saved to {}" ~~ cdir

readCache :: SessionMonad m => ServerOpts -> (FilePath -> ExceptT String IO Structured) -> m (Maybe Database)
readCache sopts act = do
	s <- getSession
	liftIO $ withSession s $ withCache sopts Nothing $ \fpath -> do
		res <- liftIO $ runExceptT $ act fpath
		either cacheErr cacheOk res
	where
		cacheErr e = sendLog Log.Error ("Error reading cache: {}" ~~ e) >> return Nothing
		cacheOk s = do
			forM_ (M.keys (structuredPackageDbs s)) $ \c -> sendLog Log.Debug ("cache read: cabal {}" ~~ show c)
			forM_ (M.keys (structuredProjects s)) $ \p -> sendLog Log.Debug ("cache read: project {}" ~~ p)
			case allModules (structuredFiles s) of
				[] -> return ()
				ms -> sendLog Log.Debug $ "cache read: {} files" ~~ length ms
			return $ Just $ merge s
