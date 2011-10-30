--------------------------------------------------------------------
-- |
-- Module    : Text.Regex.Applicative
-- Copyright : (c) Roman Cheplyaka
-- License   : MIT
--
-- Maintainer: Roman Cheplyaka <roma@ro-che.info>
-- Stability : experimental
--
-- To get started, see some examples on the wiki:
-- <https://github.com/feuerbach/regex-applicative/wiki/Examples>
--------------------------------------------------------------------

module Text.Regex.Applicative
    ( RE
    , sym
    , psym
    , anySym
    , string
    , reFoldl
    , Greediness(..)
    , few
    , match
    , (=~)
    , findFirstPrefix
    , findLongestPrefix
    , findShortestPrefix
    , module Control.Applicative
    )
    where
import Text.Regex.Applicative.Types
import Text.Regex.Applicative.Interface
import Control.Applicative
