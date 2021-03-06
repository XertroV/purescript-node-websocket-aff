module Test.Main where

import Prelude

import Data.Either (Either(..))
import Data.Foldable (for_, traverse_)
import Data.FoldableWithIndex (forWithIndex_)
import Data.List (List(Nil), fromFoldable, length, range, (!!), (:))
import Data.Maybe (Maybe(..), fromJust)
import Data.Nullable (Nullable, notNull, toNullable)
import Data.Set as Set
import Data.String (Pattern(..), split)
import Data.Traversable (sequence)
import Data.Tuple (Tuple(..), fst, snd)
import Effect (Effect)
import Effect.Aff (Aff, Milliseconds(..), delay, error, launchAff_, throwError)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Console (log) as C
import Effect.Unsafe (unsafePerformEffect)
import Node.HTTP (listen)
import Node.HTTP as HTTP
import Node.Websocket.Aff (ClientConnect, Connect, ConnectionClose, ConnectionMessage, EventProxy(EventProxy), Request, on)
import Node.Websocket.Aff.Client (connect, connect_, defaultConnectOptions, newWebsocketClient, newWebsocketClient_)
import Node.Websocket.Aff.Connection (remoteAddress, sendMessage, sendUTF, sendUTF_)
import Node.Websocket.Aff.Connection as Connection
import Node.Websocket.Aff.Request (accept, accept_, origin)
import Node.Websocket.Aff.Server (newWebsocketServer, newWebsocketServer_, shutdown_)
import Node.Websocket.Aff.Types (TextFrame(..), WSClient, WSConnection, defaultClientConfig, defaultServerConfig)
import Partial.Unsafe (unsafePartial)
import Test.QuickCheck (Result(..), assertEquals)
-- import Test.SimpleProto (testSimpleProto)
import Unsafe.Coerce (unsafeCoerce)

data AppState


modifyAVar :: forall a. AVar a -> (a -> a) -> Aff Unit
modifyAVar v f = do
    inner <- AVar.take v
    AVar.put (f inner) v

modifyAVar_ :: forall a. AVar a -> (a -> Aff a) -> Aff Unit
modifyAVar_ v f = do
    AVar.take v >>= f >>= flip AVar.put v
    
withAVar_ :: forall a. AVar a -> (a -> Aff Unit) -> Aff Unit
withAVar_ v f = AVar.read v >>= f

port :: Int
port = 42718

log :: String -> Aff Unit
log = liftEffect <<< C.log

log_ className msg = log $ className <> " | " <> msg

clog name msg = log_ "CLIENT" $ name <> " | " <> msg

slog = log_ "SERVER"

-- | Routes incoming messages to all clients except the one that sent it, and sends
-- | message history to new connections.
main :: Effect Unit
main = launchAff_ do
  _ <- sequence $ (\(Tuple name test_) -> do
    log $ "------------(" <> name <> " | start)------------\n"
    _ <- test_
    log $ "\n------------(" <> name <> " | end)------------") <$> 
      [ Tuple "server and client" testServerAndClient
      -- , Tuple "simple proto" testSimpleProto
      ]
  pure unit
  
testServerAndClient :: Aff Unit
testServerAndClient = do
  httpServer <- liftEffect $ HTTP.createServer \ _ _ -> (C.log "INIT | HTTP server created.")
  liftEffect $ listen httpServer
    {hostname: "localhost", port, backlog: Nothing} do
      C.log $ "INIT | HTTP server listening on port " <> show port

  slog "Creating server..."
  wsServer <- newWebsocketServer_ (defaultServerConfig httpServer)

  slog "Done. Initializing AVars..."
  clientsRef <- AVar.new Set.empty
  historyRef <- AVar.new Nil

  slog "Done. Setting onRequest handler..."
  on request wsServer \ req -> do
    let remoteName = show (origin req)
    slog do
      "New connection from: " <> remoteName

    conn <- accept_ req (toNullable Nothing) (origin req)
    modifyAVar clientsRef (Set.insert conn)

    slog "New connection accepted"

    -- history <- Array.freeze historyRef
    -- sending a batched history requires client-side decoding support
    
    withAVar_ historyRef \hist -> do
      _ <- sequence $ (sendUTF_ conn) <$> hist
      pure unit
    --traverse_ (map $ sendUTF conn) historyRef

    on message conn \ msg -> do
      case msg of
        Left (TextFrame {utf8Data}) -> do
          hist <- AVar.take historyRef
          AVar.put (utf8Data : hist) historyRef
          slog ("Received message (" <> remoteName <> "): " <> utf8Data)
        Right _ -> pure unit
          
      -- hist <- AVar.read historyRef
      -- _ <- sequence $ (log <<< show) <$> hist

      withAVar_ clientsRef \clients -> do
        slog $ "Clients in handler for " <> remoteName <> " : " <> show (Set.size clients)
        _ <- sequence $ (Set.toUnfoldable clients :: Array _) <#> \client -> do
          when (conn /= client) do
            slog $ "sending message to " <> remoteName <> " : " <> show (case msg of
              Left (TextFrame {utf8Data}) -> utf8Data
              Right _ -> "<< binary data >>")
            sendMessage client msg
            
        pure unit

    on close conn \ _ _ -> do
      slog ("Peer disconnected " <> remoteAddress conn)
      modifyAVar clientsRef \clients -> Set.delete conn clients
      pure unit
  
  slog "Done setting up server."

  let expected = fromFoldable [Tuple "c1" "1", Tuple "c2" "2", Tuple "c1" "3", Tuple "c3" "4", Tuple "c2" "5"]
  state <- AVar.new { last: -1, dones: 0, connections: 0 }

  c1 <- mkClient "c1" state expected
  c2 <- mkClient "c2" state expected
  c3 <- mkClient "c3" state expected

  let nClients = 3

  until_ (\_ -> do
    state_ <- AVar.read state
    -- log $ "state | connections: " <> show state_.connections <> " | dones: " <> show state_.dones
    pure $ state_.dones == nClients
  ) (\_ -> sleep $ 100.0)

  slog "Completed test."
  shutdown_ wsServer
  slog "Shutdown ws server"
  liftEffect $ HTTP.close httpServer (pure unit)
  slog "Shutdown http server"

  log "Completed test of client and server."

  where
    close = EventProxy :: EventProxy ConnectionClose
    message = EventProxy :: EventProxy ConnectionMessage
    request = EventProxy :: EventProxy Request

    until_ :: (Unit -> Aff Boolean) -> (Unit -> Aff Unit) -> Aff Unit
    until_ check' run' = do
      isDone <- check' unit
      if not isDone
        then do
          run' unit
          until_ check' run'
        else pure unit

    mkClient :: String -> _ -> _ -> Aff WSClient
    mkClient name state expected = do
      lastMsgIx <- AVar.new (-1)
      client <- newWebsocketClient_ defaultClientConfig
      connect_ client ("ws://localhost:" <> show port) $ defaultConnectOptions { origin = notNull name }
      _ <- on (EventProxy :: EventProxy ClientConnect) client \ conn -> do
        modifyAVar state \s@{connections} -> s { connections = connections + 1 }
        clog name "connected to server"
        withAVar_ state \s -> slog $ "State: " <> show s
        mkClientOnConn name conn state lastMsgIx expected
        when ((expected !! 0 <#> fst # fjup) == name) do
          sendUTF_ conn $ name <> "|" <> (expected !! 0 <#> snd # fjup)
          modifyAVar lastMsgIx \i -> 0
      pure client

    mkClientOnConn :: String -> WSConnection -> _ -> _ -> _ -> Aff Unit
    mkClientOnConn name conn state lastMsgIx expected = do
      on message conn \ msg -> do
        case msg of
          Left (TextFrame {utf8Data}) -> do
            case (split (Pattern "|") utf8Data # fromFoldable) of
              senderName : senderMsg : nil -> do
                clog name $ "from: " <> senderName <> " got: '" <> senderMsg <> "'"
                expectedIx <- (+) 1 <$> AVar.read lastMsgIx
                clog name $ "expected match: " <> show (fjup $ expected !! expectedIx)
                let (Tuple expSender expMsg) = fjup $ expected !! expectedIx
                assertEq expSender senderName
                assertEq expMsg senderMsg
                clog name $ "expected matched"
                modifyAVar lastMsgIx \_ -> expectedIx
                let nextIx = expectedIx + 1
                if length expected == nextIx
                  then do
                    clog name $ "got all expected, shuting down"
                    modifyAVar state \s@{dones} -> s { dones = dones + 1 }
                    Connection.close_ conn
                  else if (expected !! nextIx # fjup # fst) /= name
                    then do
                      clog name $ "did not match next (which was: " <> show (fjup $ expected !! nextIx) <> ")"
                    else do
                      clog name $ "will send next msg"
                      sleep 10.0
                      sendUTF_ conn $ name <> "|" <> (expected !! nextIx <#> snd # fjup)
                      modifyAVar lastMsgIx \i -> i + 1
                      clog name $ "sent msg"
                      if length expected == nextIx + 1
                        then do
                          clog name $ "sent last expected, shuting down"
                          modifyAVar state \s@{dones} -> s { dones = dones + 1 }
                          Connection.close_ conn
                        else
                          clog name $ "waiting for next msg"
                pure unit
              _ -> throwError $ error $ "Got a msg that didn't match expected format: " <> show utf8Data
          Right e -> throwError $ error $ "Got a msg that wasn't utf8: " <> unsafeCoerce e
      sleep 10.0

    sleep :: Number -> Aff Unit
    sleep n = delay $ Milliseconds n

    assertEq :: forall a. Eq a => Show a => a -> a -> Aff Unit
    assertEq a b = do 
      case assertEquals a b of
        Success -> pure unit
        Failed s -> throwError $ error s


fjup :: forall a. Maybe a -> a
fjup a = (unsafePartial fromJust) a