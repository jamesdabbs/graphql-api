{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}
-- | Tests that span the entire system.
--
-- These tests function both as examples of how to use the API, as well as
-- sanity checks on our reasoning.
module EndToEndTests (tests) where

import Protolude hiding (diff)

import Data.Aeson (Value(Null), toJSON, object, (.=))
import Data.IORef (IORef, newIORef, readIORef, modifyIORef)
import qualified Data.Map as Map
import GraphQL (makeSchema, compileQuery, executeQuery, interpretAnonymousQuery, interpretQuery, interpretRequest, SchemaRoot(..), Response)
import GraphQL.API (Object, Field, List, Argument, (:>), Defaultable(..), HasAnnotatedInputType(..))
import GraphQL.Internal.Syntax.AST (Variable(..))
import qualified GraphQL.Introspection as Introspection
import GraphQL.Resolver ((:<>)(..), Handler, unionValue)
import GraphQL.Value (ToValue(..), FromValue(..), makeName)
import Test.Tasty (TestTree)
import Test.Tasty.Hspec (testSpec, describe, it, shouldBe, runIO)
import Text.RawString.QQ (r)
import Utils

import ExampleSchema

-- | Example query root.
--
-- @
-- type QueryRoot {
--   dog: Dog
--   describeDog(dog: DEFAULT): String
-- }
-- @
--
-- Drawn from <https://facebook.github.io/graphql/#sec-Validation>.
type QueryRoot = Object "QueryRoot" '[]
  '[ Field "dog" Dog
   , Argument "dog" DogStuff :> Field "describeDog" Text
   , Field "catOrDog" CatOrDog
   , Field "catOrDogList" (List CatOrDog)
   , Introspection.SchemaField
   , Introspection.TypeField
   ]

type DogWithTreats = Object "DogWithTreats" '[]
  '[ Field "dog" Dog
   , Field "treats" Int32
   ]

type MutationRoot = Object "MutationRoot" '[]
  '[ Argument "count" Int32 :> Field "giveTreats" DogWithTreats
   ]

-- | An object that is passed as an argument. i.e. an input object.
--
-- TODO: Ideally this would be Dog itself, or ServerDog at worst.
-- Unfortunately, jml cannot figure out how to do that.
data DogStuff = DogStuff { toy :: Text, likesTreats :: Bool } deriving (Show, Generic)
instance FromValue DogStuff
instance HasAnnotatedInputType DogStuff
instance Defaultable DogStuff where
  defaultFor "dog" = pure DogStuff { toy = "shoe", likesTreats = False }
  defaultFor _ = empty

catOrDog :: Handler IO CatOrDog
catOrDog = do
  name <- pure "MonadicFelix" -- we can do monadic actions
  unionValue @Cat (catHandler name Nothing 15)

catOrDogList :: ServerDog -> Handler IO (List CatOrDog)
catOrDogList dog =
  pure [ unionValue @Cat (catHandler "Felix the Cat" (Just "felix") 42)
       , unionValue @Cat (catHandler "Henry" Nothing 10)
       , unionValue @Dog (viewServerDog dog)
       ]

catHandler :: Text -> Maybe Text -> Int32 -> Handler IO Cat
catHandler name nickName meowVolume = pure $
  pure name :<>
  pure (pure <$> nickName) :<>
  pure . const False :<>  -- doesn't know any commands
  pure meowVolume

-- | Our server's internal representation of a 'Dog'.
data ServerDog
  = ServerDog
    { name :: Text
    , nickname :: Maybe Text
    , barkVolume :: Int32
    , knownCommands :: Set DogCommand
    , houseTrainedAtHome :: Bool
    , houseTrainedElsewhere :: Bool
    , owner :: ServerHuman
    , treatCount :: IORef Int32
    }

-- | Whether 'ServerDog' knows the given command.
doesKnowCommand :: ServerDog -> DogCommand -> Bool
doesKnowCommand dog command = command `elem` knownCommands dog

-- | Whether 'ServerDog' is house-trained.
isHouseTrained :: ServerDog -> Maybe Bool -> Bool
isHouseTrained dog Nothing = houseTrainedAtHome dog || houseTrainedElsewhere dog
isHouseTrained dog (Just False) = houseTrainedAtHome dog
isHouseTrained dog (Just True) = houseTrainedElsewhere dog

-- | Present 'ServerDog' for GraphQL.
viewServerDog :: ServerDog -> Handler IO Dog
viewServerDog dog@ServerDog{..} = pure $
  pure name :<>
  pure (fmap pure nickname) :<>
  pure barkVolume :<>
  pure . doesKnowCommand dog :<>
  pure . isHouseTrained dog :<>
  viewServerHuman owner

describeDog :: DogStuff -> Handler IO Text
describeDog (DogStuff toy likesTreats)
  | likesTreats = pure $ "likes treats and their favorite toy is a " <> toy
  | otherwise = pure $ "their favorite toy is a " <> toy

rootHandler :: ServerDog -> Handler IO QueryRoot
rootHandler dog = pure $
  viewServerDog dog :<>
  describeDog :<>
  catOrDog :<>
  catOrDogList dog :<>
  Introspection.schema @E2ESchema :<>
  Introspection.type_ @E2ESchema

-- | Our server's internal representation of a 'Human'.
newtype ServerHuman = ServerHuman Text deriving (Eq, Ord, Show, Generic)


-- | Present a 'ServerHuman' as a GraphQL 'Human'.
viewServerHuman :: ServerHuman -> Handler IO Human
viewServerHuman (ServerHuman name) = pure (pure name)

-- | It me.
jml :: ServerHuman
jml = ServerHuman "jml"

type E2ESchema = SchemaRoot IO QueryRoot MutationRoot

rootMutations :: ServerDog -> IORef Int32 -> Handler IO MutationRoot
rootMutations dog treats = pure
  $ \count -> do
    modifyIORef treats (+ count)
    pure $ viewServerDog dog :<> readIORef treats

schemaHandler :: ServerDog -> IORef Int32 -> E2ESchema
schemaHandler dog treats = SchemaRoot (rootHandler dog) (rootMutations dog treats)

tests :: IO TestTree
tests = testSpec "End-to-end tests" $ do
  treatCountRef <- runIO $ newIORef 0

  let
    -- | jml has a stuffed black dog called "Mortgage".
    mortgage :: ServerDog
    mortgage = ServerDog
             { name = "Mortgage"
             , nickname = Just "Mort"
             , barkVolume = 0  -- He's stuffed
             , knownCommands = mempty  -- He's stuffed
             , houseTrainedAtHome = True  -- Never been a problem
             , houseTrainedElsewhere = True  -- Untested in the field
             , owner = jml
             , treatCount = treatCountRef
             }

  describe "interpretAnonymousQuery" $ do
    it "Handles the simplest possible valid query" $ do
      let query = [r|{
                      dog {
                        name
                      }
                    }
                   |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Handles more than one field" $ do
      let query = [r|{
                      dog {
                        name
                        barkVolume
                      }
                    }
                   |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                , "barkVolume" .= (0 :: Int32)
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Handles nested queries" $ do
      let query = [r|{
                      dog {
                        name
                        owner {
                          name
                        }
                      }
                    }
                   |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                , "owner" .= object
                  [ "name" .= ("jml" :: Text)
                  ]
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "It aliases fields" $ do
      let query = [r|{
                      dog {
                        name
                        boss: owner {
                          name
                        }
                      }
                    }
                   |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                , "boss" .= object
                  [ "name" .= ("jml" :: Text)
                  ]
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Passes arguments to functions" $ do
      let query = [r|{
                      dog {
                        name
                        doesKnowCommand(dogCommand: Sit)
                      }
                     }
                    |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                , "doesKnowCommand" .= False
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Passes arguments that are objects to functions" $ do
      let query = [r|{
                      describeDog(dog: {toy: "bone", likesTreats: true})
                     }
                    |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "describeDog" .= ("likes treats and their favorite toy is a bone" :: Text) ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Passes default arguments that are objects to functions" $ do
      let query = [r|{
                      describeDog
                     }
                    |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "describeDog" .= ("their favorite toy is a shoe" :: Text) ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Handles fairly complex queries" $ do
      let query = [r|{
                      dog {
                        callsign: name
                        ... on Dog {
                          callsign: name
                          me: owner {
                            ... on Sentient {
                              name
                            }
                            ... on Human {
                              name
                            }
                            name
                          }
                        }
                      }
                     }
                    |]
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "callsign" .= ("Mortgage" :: Text)
                , "me" .= object
                  [ "name" .= ("jml" :: Text)
                  ]
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Lets you query union types" $ do
      let query = "{ catOrDog { ... on Cat { name meowVolume } ... on Dog { barkVolume } } }"
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "catOrDog" .= object
                [ "name" .= ("MonadicFelix" :: Text)
                , "meowVolume" .= (15 :: Float)
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Lets you query lists of union types" $ do
      let query = "{ catOrDogList { ... on Cat { name meowVolume } ... on Dog { barkVolume } } }"
      response <- interpretAnonymousQuery @QueryRoot (rootHandler mortgage) query
      let expected =
            object
            [ "data" .= object
              [ "catOrDogList" .=
                [ object
                  [ "name" .= ("Felix the Cat" :: Text)
                  , "meowVolume" .= (42 :: Float)
                  ]
                , object
                  [ "name" .= ("Henry" :: Text)
                  , "meowVolume" .= (10 :: Float)
                  ]
                , object
                  [ "barkVolume" .= (0 :: Float)
                  ]
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
  describe "interpretQuery" $ do
    it "Handles the simplest named query" $ do
      let query = [r|query myQuery {
                      dog {
                        name
                      }
                    }
                   |]
      response <- interpretQuery @QueryRoot (rootHandler mortgage) query Nothing mempty
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    it "Allows calling query by name" $ do
      let query = [r|query myQuery {
                      dog {
                        name
                      }
                    }
                   |]
      let Right name = makeName "myQuery"
      response <- interpretQuery @QueryRoot (rootHandler mortgage) query (Just name) mempty
      let expected =
            object
            [ "data" .= object
              [ "dog" .= object
                [ "name" .= ("Mortgage" :: Text)
                ]
              ]
            ]
      toJSON (toValue response) `shouldBe` expected
    describe "Handles variables" $ do
      let Right schema = makeSchema @Dog
      let Right query =
            compileQuery schema
            [r|query myQuery($whichCommand: DogCommand) {
                 dog {
                   name
                   doesKnowCommand(dogCommand: $whichCommand)
                 }
               }
              |]
      let Right annotatedQuery =
            compileQuery schema
            [r|query myQuery($whichCommand: DogCommand!) {
                 dog {
                   name
                   doesKnowCommand(dogCommand: $whichCommand)
                 }
               }
              |]
      let Right badQuery =
            compileQuery schema
            [r|query myQuery($whichCommand: String!) {
                 dog {
                   name
                   doesKnowCommand(dogCommand: $whichCommand)
                 }
               }
              |]
      it "Errors when variable and argument types are in conflict" $ do
        let vars = Map.singleton (Variable "whichCommand") $ toValue @Text "cow"
        response <- executeQuery  @QueryRoot (rootHandler mortgage) badQuery Nothing vars
        let expected =
              object
              [ "data" .= object
                [ "dog" .= object
                  [ "name" .= ("Mortgage" :: Text)
                  , "doesKnowCommand" .= Null
                  ]
                ]
              , "errors" .=
                [
                  object
                  -- TODO: This error message is pretty bad. We should define
                  -- a typeclass for client-friendly "Show" (separate from
                  -- actual Show which remains extremely useful for debugging)
                  -- and use that when including values in error messages.
                  [ "message" .= ("Could not coerce Name {unName = \"dogCommand\"} to valid value: ValueScalar' (ConstString (String \"cow\")) not an enum: [Right (Name {unName = \"Sit\"}),Right (Name {unName = \"Down\"}),Right (Name {unName = \"Heel\"})]" :: Text)
                  ]
                ]
              ]
        toJSON (toValue response) `shouldBe` expected
      it "Errors when no variables provided" $ do
        response <- executeQuery  @QueryRoot (rootHandler mortgage) query Nothing mempty
        let expected =
              object
              [ "data" .= object
                [ "dog" .= object
                  [ "name" .= ("Mortgage" :: Text)
                  , "doesKnowCommand" .= Null
                  ]
                ]
              , "errors" .=
                [
                  object
                  [ "message" .= ("Could not coerce Name {unName = \"dogCommand\"} to valid value: ValueScalar' ConstNull not an enum: [Right (Name {unName = \"Sit\"}),Right (Name {unName = \"Down\"}),Right (Name {unName = \"Heel\"})]" :: Text)
                  ]
                ]
              ]
        toJSON (toValue response) `shouldBe` expected
      it "Substitutes variables when they are provided" $ do
        -- TODO: This is a crummy way to make a variable map. jml doesn't want
        -- to come up with a new API in this PR, but probably we should have a
        -- very simple function to turn a JSON value / object into the
        -- variable map that we desire. Alternatively, we should have APIs
        -- like Aeson does.
        -- <https://github.com/jml/graphql-api/issues/96>
        let Right varName = makeName "whichCommand"
        let vars = Map.singleton (Variable varName) (toValue Sit)
        response <- executeQuery  @QueryRoot (rootHandler mortgage) query Nothing vars
        let expected =
              object
              [ "data" .= object
                [ "dog" .= object
                  [ "name" .= ("Mortgage" :: Text)
                  , "doesKnowCommand" .= False
                  ]
                ]
              ]
        toJSON (toValue response) `shouldBe` expected
      it "Substitutes annotated variables when they are provided" $ do
        let Right varName = makeName "whichCommand"
        let vars = Map.singleton (Variable varName) (toValue Sit)
        response <- executeQuery  @QueryRoot (rootHandler mortgage) annotatedQuery Nothing vars
        let expected =
              object
              [ "data" .= object
                [ "dog" .= object
                  [ "name" .= ("Mortgage" :: Text)
                  , "doesKnowCommand" .= False
                  ]
                ]
              ]
        toJSON (toValue response) `shouldBe` expected
      it "Errors when non-null variable is not provided" $ do
        response <- executeQuery  @QueryRoot (rootHandler mortgage) annotatedQuery Nothing mempty
        let expected =
              object
              [ "data" .= Null
              , "errors" .=
                [
                  object
                  [ "message" .= ("Execution error: MissingValue (Variable (Name {unName = \"whichCommand\"}))" :: Text)
                  ]
                ]
              ]
        toJSON (toValue response) `shouldBe` expected

  describe "introspection" $ do
    treatRef <- runIO $ newIORef 1

    let
      run :: Text -> IO Response
      run query = interpretRequest @E2ESchema (schemaHandler mortgage treatRef) query Nothing mempty

    it "can issue direct queries" $ do
      response <- run [r|query myQuery {
         dog {
           name
         }
        }
      |]
      response `shouldBeJSON` [json|
        {
          "data": {
            "dog": {
              "name": "Mortgage"
            }
          }
        }
      |]

    it "can issue mutations" $ do
      response <- run [r|mutation goodBoy {
           giveTreats(count: 2) {
             dog {
               name
             }
             treats
           }
         }
      |]
      response `shouldBeJSON` [json|
        {
          "data": {
            "giveTreats": {
              "dog": {
                "name": "Mortgage"
              },
              "treats": 3
            }
          }
        }
      |]

    it "can fetch the __schema" $ do
      response <- run [r|{
          __schema {
            types {
              kind
              name
            }
            queryType {
              name
            }
            mutationType {
              name
            }
          }
        }|]
      response `shouldBeJSON` [json|
        {
          "data": {
            "__schema": {
              "types": [
                {
                  "kind": "OBJECT",
                  "name": "Cat"
                },
                {
                  "kind": "ENUM",
                  "name": "CatCommand"
                },
                {
                  "kind": "UNION",
                  "name": "CatOrDog"
                },
                {
                  "kind": "OBJECT",
                  "name": "Dog"
                },
                {
                  "kind": "ENUM",
                  "name": "DogCommand"
                },
                {
                  "kind": "INPUT_OBJECT",
                  "name": "DogStuff"
                },
                {
                  "kind": "OBJECT",
                  "name": "DogWithTreats"
                },
                {
                  "kind": "OBJECT",
                  "name": "Human"
                },
                {
                  "kind": "OBJECT",
                  "name": "MutationRoot"
                },
                {
                  "kind": "INTERFACE",
                  "name": "Pet"
                },
                {
                  "kind": "OBJECT",
                  "name": "QueryRoot"
                },
                {
                  "kind": "INTERFACE",
                  "name": "Sentient"
                }
              ],
              "queryType": {
                "name": "QueryRoot"
              },
              "mutationType": {
                "name": "MutationRoot"
              }
            }
          }
        }
      |]

    it "can introspect objects" $ do
      response <- run [r|{
          __type(name: "Dog") {
            kind
            name
            fields {
              name
            }
          }
        }|]
      response `shouldBeJSON` [json|
        {
          "data": {
            "__type": {
              "kind": "OBJECT",
              "name": "Dog",
              "fields": [
                { "name": "name" },
                { "name": "nickname" },
                { "name": "barkVolume" },
                { "name": "doesKnowCommand" },
                { "name": "isHouseTrained" },
                { "name": "owner" }
              ]
            }
          }
        }
      |]

    it "can introspect interfaces" $ do
      response <- run [r|{
        __type(name: "Pet") {
          kind
          name
          fields {
            name
          }
        }
      }|]
      response `shouldBeJSON` [json|{
        "data": {
          "__type": {
            "kind": "INTERFACE",
            "name": "Pet",
            "fields": [
              { "name": "name" }
            ]
          }
        }
      }|]

    it "can introspect unions" $ do
      response <- run [r|{
        __type(name: "CatOrDog") {
          kind
          name
        }
      }|]
      response `shouldBeJSON` [json|{
        "data": {
          "__type": {
            "kind": "UNION",
            "name": "CatOrDog"
          }
        }
      }|]

    it "can introspect enums" $ do
      response <- run [r|{
        __type(name: "DogCommand") {
          kind
          name
          enumValues {
            name
          }
        }
      }|]
      response `shouldBeJSON` [json|{
        "data": {
          "__type": {
            "kind": "ENUM",
            "name": "DogCommand",
            "enumValues": [
              { "name": "Sit" },
              { "name": "Down" },
              { "name": "Heel" }
            ]
          }
        }
      }|]

    it "can introspect input objects" $ do
      response <- run [r|{
        __type(name: "DogStuff") {
          kind
          name
          inputFields {
            name
          }
        }
      }|]
      response `shouldBeJSON` [json|{
        "data": {
          "__type": {
            "kind": "INPUT_OBJECT",
            "name": "DogStuff",
            "inputFields": [
              { "name": "toy" },
              { "name": "likesTreats" }
            ]
          }
        }
      }|]

    it "can introspect field input args" $ do
      response <- run [r|{
        __type(name: "MutationRoot") {
          kind
          fields {
            name
            args {
              name
            }
          }
        }
      }|]
      response `shouldBeJSON` [json|{
        "data": {
          "__type": {
            "kind": "OBJECT",
            "fields": [{
              "name": "giveTreats",
              "args": [
                { "name": "count" }
              ]
            }]
          }
        }
      }|]

    it "can serialize the schema" $ do
      let expected = "type QueryRoot{dog:Dog!,describeDog(dog:DogStuff!):String!,catOrDog:CatOrDog!,catOrDogList:[CatOrDog!]!}type Dog implements Pet{name:String!,nickname:String!,barkVolume:Int!,doesKnowCommand(dogCommand:DogCommand!):Boolean!,isHouseTrained(atOtherHomes:Boolean):Boolean!,owner:Human!}type Human implements Sentient{name:String!}input DogStuff{toy:String!,likesTreats:Boolean!}union CatOrDog=Cat|Dogtype MutationRoot{giveTreats(count:Int!):DogWithTreats!}type DogWithTreats{dog:Dog!,treats:Int!}\n,schema{query:QueryRoot,mutation:MutationRoot}"
      Introspection.serialize @E2ESchema `shouldBe` Right expected