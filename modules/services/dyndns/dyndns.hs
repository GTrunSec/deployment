{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, TypeFamilies #-}
{-# LANGUAGE TemplateHaskell, OverloadedStrings #-}
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)

import qualified Control.Concurrent.Async as A
import qualified Control.Concurrent.STM.TChan as TC
import qualified Control.Concurrent.STM.TQueue as TQ

import Control.Exception (bracket, catch, SomeException)
import Control.Monad (join, forever, (<=<))
import Control.Monad.Reader (ask)
import Control.Monad.State (get, put)

import Data.ByteString (ByteString)
import Data.Maybe (catMaybes)
import Data.String (fromString)
import Data.Typeable (Typeable)
import Data.Word (Word16, Word32)
import Data.Serialize.Text ()

import qualified Data.Acid as AS
import qualified Data.Aeson as J
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.HashMap.Strict as HM
import qualified Data.IP as IP
import qualified Data.Map.Lazy as M
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.SafeCopy as SC
import qualified Data.Serialize as S
import qualified Data.Yaml as Y
import qualified Data.Yaml.Include as YI

import GHC.Generics
import GHC.IO.Exception (IOException(IOError))

import Network.HTTP.Types (status200, status400, status401)
import Network.HTTP.Types.URI (Query)
import Network.Wai (Application, responseLBS, queryString)

import qualified Network.Wai.Handler.Warp as Warp

import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, ExitCode(..))
import System.IO (stderr, hClose)
import System.IO.Error (eofErrorType)

import qualified System.Process as P

import Text.Read (readMaybe)

import qualified Nexus

data UpdateInfo = UpdateInfo
    { uiUsername :: T.Text
    , uiPassword :: T.Text
    , uiDomain :: T.Text
    , uiIPv4Address :: Maybe IP.IPv4
    , uiIPv6Address :: Maybe IP.IPv6
    } deriving Show

type FQDN = [T.Text]

data Zone = Zone
    { zoneFQDN :: FQDN
    , zoneEmail :: FQDN
    , zoneNameservers :: [FQDN]
    , zoneSerial :: Word32
    , zoneIPv4Address :: Maybe IP.IPv4
    , zoneIPv6Address :: Maybe IP.IPv6
    } deriving (Show, Typeable, Generic)

instance S.Serialize Zone

newtype ZoneDatabase = ZoneDatabase (M.Map T.Text Zone)
    deriving (Show, Typeable)

instance SC.SafeCopy IP.IPv4 where
    putCopy = SC.contain . SC.safePut . IP.fromIPv4
    getCopy = SC.contain $ IP.toIPv4 <$> SC.safeGet

instance S.Serialize IP.IPv4

instance SC.SafeCopy IP.IPv6 where
    putCopy = SC.contain . SC.safePut . IP.fromIPv6
    getCopy = SC.contain $ IP.toIPv6 <$> SC.safeGet

instance S.Serialize IP.IPv6

$(SC.deriveSafeCopy 0 'SC.base ''Zone)
$(SC.deriveSafeCopy 0 'SC.base ''ZoneDatabase)

data UserInfo = UserInfo
    { password :: T.Text
    , domains :: [T.Text]
    } deriving (Generic, Show)

instance J.FromJSON UserInfo
instance J.ToJSON UserInfo

type Credentials = HM.HashMap T.Text UserInfo

data ConnectionConfig = ConnectionConfig
    { host :: T.Text
    , port :: Word16
    , device :: Maybe String
    } deriving (Generic, Show)

instance J.FromJSON ConnectionConfig
instance J.ToJSON ConnectionConfig

data MasterConfig = MasterConfig
    { credentials :: Credentials
    , stateDir :: FilePath
    , nameservers :: [T.Text]
    , slaves :: [ConnectionConfig]
    , email :: T.Text
    } deriving (Generic, Show)

instance J.FromJSON MasterConfig
instance J.ToJSON MasterConfig

data SlaveConfig = SlaveConfig
    { writeZoneCommand :: FilePath
    } deriving (Generic, Show)

instance J.FromJSON SlaveConfig
instance J.ToJSON SlaveConfig

type ZoneQueue = TQ.TQueue (String, BL.ByteString)

invalidIPv4Ranges :: [IP.AddrRange IP.IPv4]
invalidIPv4Ranges = map read
    -- From https://github.com/houseabsolute/Data-Validate-IP
    [ "127.0.0.0/8"     -- loopback
    , "10.0.0.0/8"      -- private
    , "172.16.0.0/12"   -- private
    , "192.168.0.0/16"  -- private
    , "192.0.2.0/24"    -- test network
    , "198.51.100.0/24" -- test network
    , "203.0.113.0/24"  -- test network
    , "192.88.99.0/24"  -- anycast
    , "224.0.0.0/4"     -- multicast
    , "169.254.0.0/16"  -- link local
    , "0.0.0.0/8"       -- unroutable
    , "100.64.0.0/10"   -- unroutable
    , "192.0.0.0/29"    -- unroutable
    , "198.18.0.0/15"   -- unroutable
    , "240.0.0.0/4"     -- unroutable
    ]

invalidIPv6Ranges :: [IP.AddrRange IP.IPv6]
invalidIPv6Ranges = map read
    -- From https://github.com/houseabsolute/Data-Validate-IP
    [ "::1/128"         -- loopback
    , "::/128"          -- unroutable
    , "::ffff:0:0/96"   -- IPv4 mapped
    , "100::/64"        -- discard
    , "2001::/23"       -- special
    , "2001::/32"       -- teredo
    , "2001:10::/28"    -- orchid
    , "2001:db8::/32"   -- documentation
    , "fc00::/7"        -- private
    , "fe80::/10"       -- link local
    , "ff00::/8"        -- multicast
    ]

parseAddress :: (IP.Addr a, Read a)
             => [IP.AddrRange a] -> ByteString -> Maybe a
parseAddress ranges bs =
    case readMaybe $ BC.unpack bs of
         Just addr -> if any (IP.isMatchedTo addr) ranges
                         then Nothing
                         else Just addr
         Nothing -> Nothing

parseIPv4 :: ByteString -> Maybe IP.IPv4
parseIPv4 = parseAddress invalidIPv4Ranges

parseIPv6 :: ByteString -> Maybe IP.IPv6
parseIPv6 = parseAddress invalidIPv6Ranges

parseQuery :: Query -> Maybe UpdateInfo
parseQuery q = UpdateInfo
    <$> fmap TE.decodeUtf8 (lu "username")
    <*> fmap TE.decodeUtf8 (lu "password")
    <*> fmap TE.decodeUtf8 (lu "domain")
    <*> pure (parseIPv4 =<< lu "ipaddr")
    <*> pure (parseIPv6 =<< lu "ip6addr")
  where lu = join . flip lookup q

mkFQDN :: T.Text -> FQDN
mkFQDN = T.split (== '.')

authenticate :: Credentials -> UpdateInfo -> Maybe UpdateInfo
authenticate cred ui =
    case HM.lookup (uiUsername ui) cred of
         Just UserInfo {
             password = passwd,
             domains  = doms
         } | uiPassword ui == passwd && uiDomain ui `elem` doms -> Just ui
         _                                                      -> Nothing

getAllZones :: AS.Query ZoneDatabase [Zone]
getAllZones = do
    ZoneDatabase db <- ask
    return $ snd <$> M.toList db

updateZone :: T.Text -> [FQDN] -> FQDN -> Maybe IP.IPv4 -> Maybe IP.IPv6
           -> AS.Update ZoneDatabase Zone
updateZone domain ns mail newV4 newV6 = do
    ZoneDatabase db <- get
    let oldZone = M.lookup domain db
    let newZone = mkUpdate oldZone
    put . ZoneDatabase $ M.insert domain newZone db
    return newZone
  where
    nextSerial :: Word32 -> Word32
    nextSerial current | current == maxBound = 1
                       | otherwise           = succ current

    updateAddr _   (Just x) = Just x
    updateAddr old _        = old

    defaultZone = Zone
        { zoneFQDN = mkFQDN domain
        , zoneEmail = mail
        , zoneNameservers = ns
        , zoneSerial = 0
        , zoneIPv4Address = Nothing
        , zoneIPv6Address = Nothing
        }

    alterZone zone = zone
        { zoneSerial = nextSerial (zoneSerial zone)
        , zoneEmail = mail
        , zoneNameservers = ns
        , zoneIPv4Address = updateAddr (zoneIPv4Address zone) newV4
        , zoneIPv6Address = updateAddr (zoneIPv6Address zone) newV6
        }

    mkUpdate Nothing = alterZone defaultZone
    mkUpdate (Just zone) = alterZone zone

$(AS.makeAcidic ''ZoneDatabase ['getAllZones, 'updateZone])

httpApp :: MasterConfig -> AS.AcidState ZoneDatabase -> TC.TChan Zone
        -> Application
httpApp cfg state workChan request respond =
    case parseQuery (queryString request) >>= authenticate (credentials cfg) of
         Nothing ->
             respondText status401 "User data wrong or incomplete."
         Just UpdateInfo {
             uiIPv4Address = Nothing,
             uiIPv6Address = Nothing
         } -> respondText status400 "IP address info wrong or incomplete."
         Just ui -> do
             newZone <- AS.update state $ UpdateZone
                 (uiDomain ui)
                 (mkFQDN <$> nameservers cfg)
                 (email2fqdn $ email cfg)
                 (uiIPv4Address ui)
                 (uiIPv6Address ui)
             atomically $ TC.writeTChan workChan newZone
             respondText status200 "DNS entry queued for update."
  where
    respondText s = respond . responseLBS s [("Content-Type", "text/plain")]

masterWorker :: AS.AcidState ZoneDatabase -> TC.TChan Zone -> ConnectionConfig
             -> IO ()
masterWorker state workChan connCfg = retry $ \conn -> do
    workQueue <- atomically $ TC.dupTChan workChan
    existing <- AS.query state GetAllZones
    mapM_ (throwIfFalse <=< Nexus.send conn) existing
    forever $ do
        newZone <- atomically $ TC.readTChan workQueue
        logBSLn ["Zone update: ", BC.pack $ show newZone]
        throwIfFalse =<< Nexus.send conn newZone
  where
    errDesc = "Connection closed by the remote side."
    eofError = IOError Nothing eofErrorType "connect" errDesc Nothing Nothing
    throwIfFalse False = ioError eofError
    throwIfFalse True  = return ()
    sHost = fromString . T.unpack $ host connCfg
    sPort = show $ port connCfg
    handleError :: SomeException -> IO ()
    handleError err = do
        logBSLn [ "Connection to slave ", BC.pack sHost, ":", BC.pack sPort
                , " has failed (", BC.pack $ show err
                , "), retrying in one second..."
                ]
        threadDelay 1000000
    retry handler = do
        catch (Nexus.connect sHost sPort (device connCfg) handler) handleError
        retry handler

defaultMasterConfig :: MasterConfig
defaultMasterConfig = MasterConfig
    { credentials = HM.empty
    , stateDir = "/tmp/dyndns.state"
    , nameservers = []
    , slaves = []
    , email = "unconfigured@example.org"
    }

defaultSlaveConfig :: SlaveConfig
defaultSlaveConfig = SlaveConfig "false"

mergeConfig :: J.Value -> J.Value -> J.Value
mergeConfig (J.Object x) (J.Object y) = J.Object $ HM.unionWith mergeConfig x y
mergeConfig _ x = x

loadConfigAndRun :: (J.ToJSON a, J.FromJSON b)
                 => FilePath -> a -> (b -> IO (Either ByteString ()))
                 -> IO (Either ByteString ())
loadConfigAndRun fp defcfg fun = do
    cfg <- YI.decodeFileEither fp
    case cfg of
         Left err  -> return . Left $ BC.pack $ Y.prettyPrintParseException err
         Right val -> do
             let val' = mergeConfig (J.toJSON defcfg) val
             case J.fromJSON val' of
                  J.Error s -> return . Left $ BC.concat
                      ["Could not convert to settings: ", BC.pack s]
                  J.Success settings -> fun settings

serveManyWarps :: Application -> IO [A.Async ()]
serveManyWarps app =
    mapM A.async . fmap listenTo <=< Nexus.getSocketsFor $ Just "http"
  where
    listenTo :: Nexus.Socket -> IO ()
    listenTo sock = do
        Nexus.setNonBlocking sock
        Warp.runSettingsSocket Warp.defaultSettings sock app

startMaster :: MasterConfig -> IO (Either ByteString ())
startMaster MasterConfig { nameservers = [] } =
    return $ Left "No nameservers defined in config"
startMaster cfg = bracket openAcidState AS.closeAcidState $ \state -> do
    workChan <- TC.newBroadcastTChanIO
    slaveWorkers <- mapM (A.async . masterWorker state workChan) $ slaves cfg
    warps <- serveManyWarps $ httpApp cfg state workChan
    snd <$> A.waitAnyCancel (slaveWorkers ++ warps)
    return $ Right ()
  where
    openAcidState = AS.openLocalStateFrom (stateDir cfg) (ZoneDatabase M.empty)

mkRR :: ByteString -> [ByteString] -> ByteString
mkRR rrType rrData = BC.intercalate " " (["@", "IN", rrType] ++ rrData)

mkSimpleRR :: ByteString -> ByteString -> ByteString
mkSimpleRR rrType = mkRR rrType . (:[])

fqdn2zone :: FQDN -> ByteString
fqdn2zone fqdn = BC.snoc (BC.intercalate "." $ TE.encodeUtf8 <$> fqdn) '.'

email2fqdn :: T.Text -> FQDN
email2fqdn = T.split (`elem` ['@', '.'])

mkSOA :: FQDN -> FQDN -> Word32 -> ByteString
mkSOA primNS mail serial =
    mkRR "SOA" $ [fqdn2zone primNS, fqdn2zone mail] ++ times
  where
    times :: [ByteString]
    times = (BC.pack . show) <$> [serial, 60, 60, 14400, 0]

generateZoneFile :: Zone -> BL.ByteString
generateZoneFile z = BL.unlines $ BL.fromStrict <$> zoneLines
  where zoneLines = [defTTL, soa] ++ ns ++ aRecords
        defTTL = "$TTL 0"
        soa = mkSOA (head $ zoneNameservers z) (zoneEmail z) (zoneSerial z)
        ns = mkSimpleRR "NS" . fqdn2zone <$> zoneNameservers z
        aRecords = catMaybes
            [ mkSimpleRR "A" . BC.pack . show <$> zoneIPv4Address z
            , mkSimpleRR "AAAA" . BC.pack . show <$> zoneIPv6Address z
            ]

logBSLn :: [ByteString] -> IO ()
logBSLn = BC.hPutStrLn stderr . BC.concat

logBS :: [ByteString] -> IO ()
logBS = BC.hPutStr stderr . BC.concat

updateZoneFile :: FilePath -> String -> BL.ByteString -> IO ()
updateZoneFile cmd zone zoneData = do
    logBSLn ["Updating zone ", BC.pack zone, "..."]
    exitCode <- bracket (P.createProcess procCmd) cleanup process
    case exitCode of
         ExitSuccess -> logBSLn ["Updating of zone ", BC.pack zone, " done."]
         ExitFailure code -> logBSLn
            [ "Failed to update zone ", BC.pack zone
            , " with exit code ", BC.pack $ show code, "."
            ]
  where
    procCmd = (P.proc cmd [zone]) {
        P.std_in = P.CreatePipe,
        P.close_fds = True
    }
    cleanup (Just i, _, _, p) = do
        hClose i
        P.terminateProcess p
    cleanup _ = error "This should never happen"
    process (Just i, _, _, p) = do
        BL.hPutStrLn i zoneData
        hClose i
        P.waitForProcess p
    process _ = error "This should never happen"

slaveZoneUpdater :: FilePath -> ZoneQueue -> IO ()
slaveZoneUpdater cmd zoneQueue = forever $
    atomically (TQ.readTQueue zoneQueue) >>= uncurry (updateZoneFile cmd)

slaveHandler :: ZoneQueue -> FilePath -> Zone -> IO ()
slaveHandler _ _ Zone { zoneFQDN = fqdn, zoneNameservers = [] } =
    logBSLn ["No nameservers found for ", fqdn2zone fqdn]
slaveHandler zoneQueue cmd zone = do
    logBS
        ["Scheduling update of zone ", zoneBS
        , " with serial ", BC.pack . show $ zoneSerial zone
        , " using command ", BC.pack cmd
        , "..."
        ]
    atomically $ TQ.writeTQueue zoneQueue (fqdnArg, generateZoneFile zone)
    BC.hPutStrLn stderr " done."
  where
    zoneBS = BC.intercalate "." $ TE.encodeUtf8 <$> zoneFQDN zone
    fqdnArg = T.unpack $ T.intercalate "." $ zoneFQDN zone

startSlave :: SlaveConfig -> IO (Either ByteString ())
startSlave SlaveConfig { writeZoneCommand = cmd } = do
    Nexus.serve (Just "master") scc
    return $ Right ()
  where process zq c = do
            result <- Nexus.recv c
            case result of
                 Just newZone -> do
                     slaveHandler zq cmd newZone
                     process zq c
                 Nothing -> return ()
        scc c = do
            logBSLn ["New connection from master on ", BC.pack $ show c, "."]
            zoneQueue <- TQ.newTQueueIO
            let updater = slaveZoneUpdater cmd zoneQueue
            A.race_ updater $ process zoneQueue c

realMain :: [String] -> IO (Either ByteString ())
realMain ["--master", cfgFile] =
    loadConfigAndRun cfgFile defaultMasterConfig startMaster
realMain ["--slave", cfgFile] =
    loadConfigAndRun cfgFile defaultSlaveConfig startSlave
realMain _ = do
    prog <- getProgName
    return . Left . BC.concat $
        ["Usage: ", BC.pack prog, " {--master|--slave} configfile.yaml"]

main :: IO ()
main = do
    args <- getArgs
    result <- realMain args
    case result of
         Left s -> BC.hPutStrLn stderr s >> exitFailure
         Right r -> return r
