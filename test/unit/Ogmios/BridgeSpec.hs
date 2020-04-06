-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Ogmios.BridgeSpec
    ( spec
    ) where

import Prelude

import Cardano.Chain.Byron.API
    ( ApplyMempoolPayloadErr (..) )
import Cardano.Chain.UTxO.Validation
    ( UTxOValidationError )
import Data.Aeson
    ( ToJSON (..) )
import Data.String
    ( IsString )
import Data.Text
    ( Text )
import JSONSchema.Draft4
    ( Schema (..)
    , SchemaWithURI (..)
    , ValidatorFailure (..)
    , checkSchema
    , emptySchema
    , referencesViaFilesystem
    )
import JSONSchema.Validator.Draft4.Any
    ( OneOfInvalid (..), RefInvalid (..) )
import JSONSchema.Validator.Draft4.Object
    ( PropertiesRelatedInvalid (..) )
import Ogmios.Bridge
    ( FindIntersectResponse (..)
    , RequestNextResponse (..)
    , SubmitTxResponse (..)
    )
import Ouroboros.Consensus.Byron.Ledger
    ( ByronBlock )
import Ouroboros.Network.Block
    ( BlockNo (..), Point (..), Tip (..), blockPoint, legacyTip )
import Test.Cardano.Chain.UTxO.Gen
    ( genUTxOValidationError )
import Test.Hspec
    ( Spec, SpecWith, describe, it )
import Test.QuickCheck
    ( Arbitrary (..)
    , Positive (..)
    , Property
    , counterexample
    , genericShrink
    , oneof
    , property
    , withMaxSuccess
    )
import Test.QuickCheck.Arbitrary.Generic
    ( genericArbitrary )
import Test.QuickCheck.Hedgehog
    ( hedgehog )
import Test.QuickCheck.Monadic
    ( assert, monadicIO, monitor, run )

import Cardano.Byron.Types.Json.Orphans
    ()
import Test.Consensus.Byron.Ledger
    ()

import qualified Codec.Json.Wsp.Handler as Wsp
import qualified Data.Aeson as Json
import qualified Data.Aeson.Encode.Pretty as Json
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T

spec :: Spec
spec =
    describe "validate ToJSON instances against JSON-schema" $ do
        test (validateAllToJSON @(FindIntersectResponse ByronBlock))
            "ogmios.wsp.json#/properties/FindIntersectResponse"
        test (validateAllToJSON @(RequestNextResponse ByronBlock))
            "ogmios.wsp.json#/properties/RequestNextResponse"
        test (validateAllToJSON @(SubmitTxResponse ApplyMempoolPayloadErr))
            "ogmios.wsp.json#/properties/SubmitTxResponse"

--
-- Helpers
--

newtype SchemaRef = SchemaRef
    { getSchemaRef :: Text }
    deriving (Show, IsString)

validateAllToJSON
    :: ToJSON (Wsp.Response a)
    => SchemaRef
    -> Wsp.Response a
    -> Property
validateAllToJSON ref a = monadicIO $ do
    let json = toJSON a
    errors <- run $ validateSchema ref json
    monitor $ counterexample $ unlines
        [ "json:", BL8.unpack $ Json.encodePretty json ]
    monitor $ counterexample $ unlines
        (prettyFailure <$> errors)
    assert (null errors)

validateSchema :: SchemaRef -> Json.Value -> IO [ValidatorFailure]
validateSchema (SchemaRef ref) value = do
    let schema = SchemaWithURI (emptySchema { _schemaRef = Just ref }) Nothing
    refs <- unsafeIO =<< referencesViaFilesystem schema
    validate <- unsafeIO (checkSchema refs schema)
    pure $ validate value
  where
    unsafeIO :: Show e => Either e a -> IO a
    unsafeIO = either (fail . show) pure

test
    :: forall a. (Arbitrary a, Show a)
    => (SchemaRef -> a -> Property)
    -> SchemaRef
    -> SpecWith ()
test prop ref =
    it (T.unpack $ getSchemaRef ref) $ withMaxSuccess 100 $ property $ prop ref

prettyFailure
    :: ValidatorFailure
    -> String
prettyFailure = \case
    FailureRef (RefInvalid _ schema errs) -> unlines
        [ "schema:", BL8.unpack $ Json.encodePretty schema
        , "errors:", unlines $ indent $ prettyFailure <$> NE.toList errs
        ]

    FailureOneOf (NoSuccesses xs _) ->
        unlines $ concatMap (fmap prettyFailure . NE.toList . snd) $ NE.toList xs

    FailurePropertiesRelated (PropertiesRelatedInvalid prop reg extra) -> unlines
        [ "properties: " <> show prop
        , "pattern: " <> show reg
        , "additional: " <> show extra
        ]

    anythingElse ->
        show anythingElse

  where
    indent xs = ("    " <>) <$> xs

--
-- Instances
--

instance Arbitrary a => Arbitrary (Wsp.Response a) where
    arbitrary = Wsp.Response Nothing <$> arbitrary

instance Arbitrary (FindIntersectResponse ByronBlock) where
    shrink = genericShrink
    arbitrary = genericArbitrary

instance Arbitrary (RequestNextResponse ByronBlock) where
    shrink = genericShrink
    arbitrary = genericArbitrary

instance Arbitrary (SubmitTxResponse ApplyMempoolPayloadErr) where
    arbitrary = oneof
        [ pure (SubmitTxResponse Nothing)
        , SubmitTxResponse . Just . MempoolTxErr <$> arbitrary
        ]

instance Arbitrary (Point ByronBlock) where
    arbitrary = blockPoint <$> arbitrary

instance Arbitrary (Tip ByronBlock) where
    arbitrary = legacyTip <$> arbitrary <*> arbitrary

instance Arbitrary BlockNo where
    arbitrary = BlockNo <$> (getPositive <$> arbitrary)

instance Arbitrary UTxOValidationError where
    arbitrary = hedgehog genUTxOValidationError
