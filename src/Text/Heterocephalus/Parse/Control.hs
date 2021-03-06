{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Text.Heterocephalus.Parse.Control where

#if MIN_VERSION_base(4,9,0)
#else
import Control.Applicative ((<$>), (*>), (<*), pure)
#endif
import Control.Monad (guard, void)
import Control.Monad.Reader (Reader, runReaderT)
import Data.Char (isUpper)
import Data.Data (Data)
import Data.Functor (($>))
import Data.Functor.Identity (runIdentity)
import Data.Typeable (Typeable)
import Text.Parsec
       (Parsec, ParsecT, (<?>), (<|>), alphaNum, between, char, choice,
        eof, many, many1, manyTill, mkPT, noneOf, oneOf, option, optional,
        runParsecT, runParserT, sepBy, skipMany, spaces, string,
        try)
import Text.Shakespeare.Base
       (Ident(Ident), Deref, parseDeref, parseVar)

import Text.Hamlet.Parse
import Text.Heterocephalus.Parse.Option
       (ParseOptions, getControlPrefix, getVariablePrefix)

data Control
  = ControlForall Deref Binding
  | ControlEndForall
  | ControlIf Deref
  | ControlElse
  | ControlElseIf Deref
  | ControlEndIf
  | ControlCase Deref
  | ControlCaseOf Binding
  | ControlEndCase
  | NoControl Content
  deriving (Data, Eq, Read, Show, Typeable)

data Content = ContentRaw String
             | ContentVar Deref
    deriving (Data, Eq, Read, Show, Typeable)

type UserParser = ParsecT String () (Reader ParseOptions)

parseLineControl :: ParseOptions -> String -> Either String [Control]
parseLineControl opts s =
  let readerT = runParserT lineControl () "" s
      res = runIdentity $ runReaderT readerT opts
  in case res of
       Left e -> Left $ show e
       Right x -> Right x

lineControl :: UserParser [Control]
lineControl = manyTill control $ try eof >> return ()

control :: UserParser Control
control = noControlVariable <|> controlStatement <|> noControlRaw
  where
    controlStatement :: UserParser Control
    controlStatement = do
      x <- parseControlStatement
      case x of
        Left str -> return (NoControl $ ContentRaw str)
        Right ctrl -> return ctrl

    noControlVariable :: UserParser Control
    noControlVariable = do
      variablePrefix <- getVariablePrefix
      x <- identityToReader $ parseVar variablePrefix
      return . NoControl $
        case x of
          Left str -> ContentRaw str
          Right deref -> ContentVar deref

    noControlRaw :: UserParser Control
    noControlRaw = do
      controlPrefix <- getControlPrefix
      variablePrefix <- getVariablePrefix
      (NoControl . ContentRaw) <$>
        many (noneOf [controlPrefix, variablePrefix])

parseControlStatement :: UserParser (Either String Control)
parseControlStatement = do
  a <- parseControl
  optional eol
  return a
 where
  eol :: UserParser ()
  eol = void (char '\n') <|> void (string "\r\n")

parseControl :: UserParser (Either String Control)
parseControl = do
  controlPrefix <- getControlPrefix
  void $ char controlPrefix
  let escape = char '\\' $> Left [controlPrefix]
  escape <|>
    (Right <$> parseControlBetweenBrackets) <|>
    return (Left [controlPrefix])

parseControlBetweenBrackets :: UserParser Control
parseControlBetweenBrackets =
  between (char '{') (char '}') $ spaces *> parseControl' <* spaces

parseControl' :: UserParser Control
parseControl' =
  try parseForall <|> try parseEndForall <|> try parseIf <|> try parseElseIf <|>
  try parseElse <|>
  try parseEndIf <|>
  try parseCase <|>
  try parseCaseOf <|>
  try parseEndCase
  where
    parseForall :: UserParser Control
    parseForall = do
      string "forall" *> spaces
      (x, y) <- binding
      pure $ ControlForall x y

    parseEndForall :: UserParser Control
    parseEndForall = string "endforall" $> ControlEndForall

    parseIf :: UserParser Control
    parseIf =
      string "if" *> spaces *> fmap ControlIf (identityToReader parseDeref)

    parseElseIf :: UserParser Control
    parseElseIf =
      string "elseif" *>
      spaces *>
      fmap ControlElseIf (identityToReader parseDeref)

    parseElse :: UserParser Control
    parseElse = string "else" $> ControlElse

    parseEndIf :: UserParser Control
    parseEndIf = string "endif" $> ControlEndIf

    parseCase :: UserParser Control
    parseCase =
      string "case" *>
      spaces *>
      fmap ControlCase (identityToReader parseDeref)

    parseCaseOf :: UserParser Control
    parseCaseOf = string "of" *> spaces *> fmap ControlCaseOf identPattern

    parseEndCase :: UserParser Control
    parseEndCase = string "endcase" $> ControlEndCase

    binding :: UserParser (Deref, Binding)
    binding = do
      y <- identPattern
      spaces
      _ <- string "<-"
      spaces
      x <- identityToReader parseDeref
      _ <- spaceTabs
      return (x, y)

    spaceTabs :: UserParser String
    spaceTabs = many $ oneOf " \t"

    -- | Parse an indentifier.  This is an sequence of alphanumeric characters,
    -- or an operator.
    ident :: UserParser Ident
    ident = do
      i <- (many1 (alphaNum <|> char '_' <|> char '\'')) <|> try operator
      white
      return (Ident i) <?> "identifier"

    -- | Parse an operator.  An operator is a sequence of characters in
    -- 'operatorList' in between parenthesis.
    operator :: UserParser String
    operator = do
      oper <- between (char '(') (char ')') . many1 $ oneOf operatorList
      pure $ oper

    operatorList :: String
    operatorList = "!#$%&*+./<=>?@\\^|-~:"

    parens :: UserParser a -> UserParser a
    parens = between (char '(' >> white) (char ')' >> white)

    brackets :: UserParser a -> UserParser a
    brackets = between (char '[' >> white) (char ']' >> white)

    braces :: UserParser a -> UserParser a
    braces = between (char '{' >> white) (char '}' >> white)

    comma :: UserParser ()
    comma = char ',' >> white

    atsign :: UserParser ()
    atsign = char '@' >> white

    equals :: UserParser ()
    equals = char '=' >> white

    white :: UserParser ()
    white = skipMany $ char ' '

    wildDots :: UserParser ()
    wildDots = string ".." >> white

    -- | Return 'True' if 'Ident' is a variable.  Variables are defined as
    -- starting with a lowercase letter.
    isVariable :: Ident -> Bool
    isVariable (Ident (x:_)) = not (isUpper x)
    isVariable (Ident []) = error "isVariable: bad identifier"

    -- | Return 'True' if an 'Ident' is a constructor.  Constructors are
    -- defined as either starting with an uppercase letter, or being an
    -- operator.
    isConstructor :: Ident -> Bool
    isConstructor (Ident (x:_)) = isUpper x || elem x operatorList
    isConstructor (Ident []) = error "isConstructor: bad identifier"

    -- | This function tries to parse an entire pattern binding with either
    -- @'gcon' True@ or 'apat'.  For instance, in the pattern
    -- @let Foo a b = ...@, this function tries to parse @Foo a b@ with 'gcon'.
    -- In the pattern @let n = ...@, this function tries to parse @n@ with
    -- 'apat'.
    identPattern :: UserParser Binding
    identPattern = gcon True <|> apat
      where
        apat :: UserParser Binding
        apat = choice [varpat, gcon False, parens tuplepat, brackets listpat]

        -- | Parse a variable in a pattern.  For instance in, in a pattern like
        -- @let Just n = ...@, this function would be what is used to parse the
        -- @n@.  This function also handles aliases with @\@@.
        varpat :: UserParser Binding
        varpat = do
          v <-
            try $ do
              v <- ident
              guard (isVariable v)
              return v
          option (BindVar v) $ do
            atsign
            b <- apat
            return (BindAs v b) <?> "variable"

        -- | This function tries to parse an entire pattern binding.  For
        -- instance, in the pattern @let Foo a b = ...@, this function tries to
        -- parse @Foo a b@.
        --
        -- This function first tries to parse a data contructor (using
        -- 'dataConstr').  In the example above, that would be like parsing
        -- @Foo@.
        --
        -- Then, the function tries to do two different things.
        --
        -- 1. It tries to parse record syntax with 'record'.  In a pattern like
        -- @let Foo{foo1 = 3, foo2 = "hello"} = ...@, it would parse the
        -- @{foo1 = 3, foo2 = "hello"}@ part.
        --
        -- 2. If parsing the record syntax fails, it then tries to parse
        -- many normal patterns with 'apat'.  In a pattern like
        -- @let Foo a b = ...@, it would be like parsing the @a b@ part.
        --
        -- If that fails, then it just returns the original data contructor
        -- with no arguments.
        --
        -- The 'Bool' argument determines whether or not it tries to parse
        -- normal patterns in 2.  If the boolean argument is 'True', then it
        -- tries parsing normal patterns in 2.  If the boolean argument is
        -- 'False', then 2 is skipped altogether.
        gcon :: Bool -> UserParser Binding
        gcon allowArgs = do
          c <- try dataConstr
          choice
            [ record c
            , fmap (BindConstr c) (guard allowArgs >> many apat)
            , return (BindConstr c [])
            ] <?>
            "constructor"

        -- | Parse a possibly qualified identifier using 'ident'.
        dataConstr :: UserParser DataConstr
        dataConstr = do
          p <- dcPiece
          ps <- many dcPieces
          return $ toDataConstr p ps

        dcPiece :: UserParser String
        dcPiece = do
          x@(Ident y) <- ident
          guard $ isConstructor x
          return y

        dcPieces :: UserParser String
        dcPieces = do
          _ <- char '.'
          dcPiece

        toDataConstr :: String -> [String] -> DataConstr
        toDataConstr x [] = DCUnqualified $ Ident x
        toDataConstr x (y:ys) = go (x :) y ys
          where
            go :: ([String] -> [String]) -> String -> [String] -> DataConstr
            go front next [] = DCQualified (Module $ front []) (Ident next)
            go front next (rest:rests) = go (front . (next :)) rest rests

        record :: DataConstr -> UserParser Binding
        record c =
          braces $ do
            (fields, wild) <- option ([], False) go
            return (BindRecord c fields wild)
          where
            go :: UserParser ([(Ident, Binding)], Bool)
            go =
              (wildDots >> return ([], True)) <|>
              (do x <- recordField
                  (xs, wild) <- option ([], False) (comma >> go)
                  return (x : xs, wild))

        recordField :: UserParser (Ident, Binding)
        recordField = do
          field <- ident
          p <-
            option
              (BindVar field) -- support punning
              (equals >> identPattern)
          return (field, p)

        tuplepat :: UserParser Binding
        tuplepat = do
          xs <- identPattern `sepBy` comma
          return $
            case xs of
              [x] -> x
              _ -> BindTuple xs

        listpat :: UserParser Binding
        listpat = BindList <$> identPattern `sepBy` comma

identityToReader :: Parsec String () a -> UserParser a
identityToReader p =
  mkPT $ pure . fmap (pure . runIdentity) . runIdentity . runParsecT p
