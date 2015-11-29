{-# LANGUAGE OverloadedStrings, RecursiveDo, LambdaCase, ScopedTypeVariables #-}
module Main where

import Common.Api

import Reflex.Dom
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LBS
import Data.Text.Encoding
import Control.Monad.IO.Class
import Control.Monad
import Data.Maybe
import Data.Monoid
import Control.Monad.Trans.Maybe
import GHCJS.DOM.Element
import Data.Time.Format
import qualified Data.Map as Map

main :: IO ()
main = mainWidgetWithHead headTag $ elAttr "div" flexContainer $ do
  (nick, recipient, dms) <- elAttr "div" flexNav $ do
    n <- el "div" nickInput
    dm <- el "div" addDirectMessage
    dms <- foldDyn (\x -> Map.insert (Just x) x) Map.empty dm
    rec dmSel <- divClass "list-group" $ selectViewListWithKey_ dmSel' dms $ \_ v s -> do
          style <- forDyn s $ \active -> "style" =: "cursor: pointer;" <> "class" =: ("list-group-item" <> if active then " active" else "")
          liftM (domEvent Click . fst) $ elDynAttr' "a" style $ dynText =<< mapDyn (T.unpack . unNick) v
        dmSel' <- holdDyn Nothing dmSel
    return (n, dmSel', dms)
  elAttr "div" flexContent $ do
    rec let send = textInputGetEnter i
        let wsUp = mconcat [ fmapMaybe (fmap $ (:[]) . Up_Message) $ tag (directMessage <$> current nick <*> current recipient <*> current (value i)) send
                           , fmapMaybe (fmap $ (:[]) . Up_RemoveNick) (tag (current nick) $ updated nick)
                           , fmapMaybe (fmap $ (:[]) . Up_AddNick) (updated nick)
                           ]
        wsDown <- openWebSocket wsUp
        let newMsg = fmapMaybe (\x -> case x of Just (Down_Message e) -> Just e; _ -> Nothing) wsDown
        listWithKey dms $ \k dm -> do
          let relevantMessage = ffilter (\(Envelope _ m) -> k == Just (_message_from m) || (fmap Left k) == Just (_message_to m)) newMsg
          dmHistory relevantMessage dm =<< mapDyn (== k) recipient
        i <- textInput $ def & setValue .~ ("" <$ send)
                             & attributes .~ tAttrs
        tAttrs <- mapDyn (\r -> if isNothing r then "style" =: "display: none;" else "class" =: "form-control") recipient
    return ()
  where
    flexContainer = "style" =: "display: flex;"
    flexNav = "style" =: "flex: 1 1 20%; order: 1;"
    flexContent = "style" =: "flex: 1 1 80%; order: 2; display: flex; flex-direction: column; margin-top: auto; overflow: hidden; height: 100vh;"
    headTag = forM_ [ "//maxcdn.bootstrapcdn.com/font-awesome/4.5.0/css/font-awesome.min.css"
                    , "//maxcdn.bootstrapcdn.com/bootstrap/3.3.6/css/bootstrap.min.css"
                    ] $ \x -> elAttr "link" ("rel" =: "stylesheet" <> "href" =: x) $ return ()

dmHistory :: MonadWidget t m => Event t (Envelope Message) -> Dynamic t Nick -> Dynamic t Bool -> m ()
dmHistory relevantMessage r visible = do
  showHide <- mapDyn (\v -> if v then historyAttr else "style" =: "display: none;") visible
  (hEl, _) <- elDynAttr' "div" showHide $ history relevantMessage
  scroll <- delay 0.1 relevantMessage
  performEvent_ $ fmap (\_ -> let h = _el_element hEl in liftIO $ elementSetScrollTop h =<< elementGetScrollHeight h) scroll
  where
    historyAttr = "style" =: "overflow: auto; height: calc(100% - 26px);"


openWebSocket :: MonadWidget t m => Event t [Up] -> m (Event t (Maybe Down))
openWebSocket wsUp = do
  wv <- askWebView
  host <- liftIO $ getLocationHost wv
  protocol <- liftIO $ getLocationProtocol wv
  let wsProtocol = case protocol of
                     "file:" -> "ws:"
                     "http:" -> "ws:"
                     "https:" -> "wss:"
                     _ -> error "Unrecognized protocol: " <> protocol
      wsHost = case protocol of
                 "file:" -> "localhost:8000"
                 _ -> host
  ws <- webSocket (wsProtocol <> "//" <> wsHost <> "/api") $ def
    & webSocketConfig_send .~ fmap (fmap (LBS.toStrict . encode)) wsUp
  return $ fmap (decode' . LBS.fromStrict)$ _webSocket_recv ws

directMessage :: Maybe Nick -> Maybe Nick -> String -> Maybe Message
directMessage sender recipient msg = Message <$> sender <*> (Left <$> recipient) <*> validMessageBody (T.pack msg)

validMessageBody :: Text -> Maybe Text
validMessageBody t = if T.null (T.strip t) then Nothing else Just t

nickInput :: MonadWidget t m => m (Dynamic t (Maybe Nick))
nickInput = do
  n <- textInput $ def & attributes .~ (constDyn $ "class" =: "form-control")
  addNick <- button "Add Nick"
  nick <- holdDyn Nothing $ tag (validNick . T.pack <$> current (value n)) $ leftmost [addNick, textInputGetEnter n]
  (nickMsgAttr, nickMsg) <- splitDyn <=< forDyn nick $ \case
    Nothing -> ("style" =: "color: red;", "No nickname set!")
    Just n -> ("style" =: "color: green;", "Hi, " <> (T.unpack $ unNick n) <> "!")
  elDynAttr "small" nickMsgAttr $ dynText nickMsg
  return nick

recipientNickInput :: MonadWidget t m => m (Dynamic t (Maybe Nick))
recipientNickInput = do
  rec recipient <- mapDyn (validNick . T.pack) <=< fmap value $ textInput $ def & attributes .~ validationAttrs
      validationAttrs <- forDyn recipient $ \r -> "class" =: "form-control" <> if isNothing r then "style" =: "border: 1px red solid;" <> "placeholder" =: "Enter recipient" else mempty
  return recipient

addDirectMessage :: MonadWidget t m => m (Event t Nick)
addDirectMessage = do
  divClass "input-group" $ do
    rec t <- textInput $ def & attributes .~ (constDyn $ "class" =: "form-control" <> "placeholder" =: "Add DM")
                             & setValue .~ ("" <$ newNick)
        b <- elClass "span" "input-group-btn" $ buttonClass "btn btn-default" $ elClass "i" "fa fa-plus" $ return ()
        let newNick = fmapMaybe (validNick . T.pack) $ tag (current (value t)) $ leftmost [textInputGetEnter t, b]
    return newNick

buttonClass :: MonadWidget t m => String -> m a -> m (Event t ())
buttonClass klass child = liftM (domEvent Click . fst) $ elAttr' "button" ("type" =: "button" <> "class" =: klass) child

validNick :: Text -> Maybe Nick
validNick t = if T.null (T.strip t) then Nothing else Just $ Nick t

history :: MonadWidget t m => Event t (Envelope Message) -> m ()
history newMsg = do
  msgs <- foldDyn (\new old -> reverse $ new : reverse old) [] newMsg
  simpleList msgs (el "div" . displayMessage)
  return ()

displayMessage :: MonadWidget t m => Dynamic t (Envelope Message) -> m ()
displayMessage em = do
  t <- mapDyn _envelope_time em
  m <- mapDyn _envelope_contents em
  let timestampFormat = formatTime defaultTimeLocale "%r"
  elAttr "span" ("style" =: "color: lightgray; font-family: monospace;") $ dynText =<< mapDyn (\x -> "(" <> timestampFormat x <> ") ") t
  elAttr "span" ("style" =: "color: red;") $ dynText =<< mapDyn ((<>": ") . T.unpack . unNick . _message_from) m
  el "span" $ dynText =<< mapDyn (T.unpack . _message_body) m

