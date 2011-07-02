{-# LANGUAGE GADTs, Rank2Types, TupleSections, DeriveFunctor #-}
module RegExp where
import Control.Applicative hiding (empty)
import qualified Control.Applicative as Applicative
import Data.Functor.Compose
import Data.List
import Control.Monad.Cont
import Data.Maybe
import Data.Traversable
import qualified Data.Sequence as Sequence

newtype RE s a = RE { unRE :: forall r . RegexpNode s r a }

-- | An applicative functor similar to Maybe, but it's '<|>' method honors
-- priority.
data Priority a = Priority { priority :: !PrSeq, pValue :: a } | Fail
    deriving Functor
type PrSeq = Sequence.Seq PrNum
type PrNum = Int

instance Applicative Priority where
    pure x = Priority Sequence.empty x
    Priority p1 f <*> Priority p2 x = Priority (p1 Sequence.>< p2) (f x)
    _ <*> _ = Fail

instance Alternative Priority where
    empty = Fail
    p@Priority {} <|> Fail = p
    Fail <|> p@Priority {} = p
    Fail <|> Fail = Fail
    p1@Priority {} <|> p2@Priority {} =
        case compare (priority p1) (priority p2) of
            LT -> p2
            GT -> p1
            EQ -> error $
                "Two priorities are the same! Should not happen.\n" ++ show (priority p1)


-- Adds priority to the end
withPriority :: PrNum -> Priority a -> Priority a
withPriority p (Priority ps x) = Priority (ps Sequence.|> p) x
withPriority _ Fail = Fail

-- Overwrite the priority
--setPriority :: PrSeq -> Priority a -> Priority a

-- Discards priority information
priorityToMaybe :: Priority a -> Maybe a
priorityToMaybe p =
    case p of
        Priority { pValue = x } -> Just x
        Fail -> Nothing

data Regexp s r a where
    Eps :: Regexp s r a
    Symbol :: (s -> Bool) -> Regexp s r s
    Alt :: RegexpNode s r a -> RegexpNode s r a -> Regexp s r a
    App :: RegexpNode s (a -> r) (a -> b) -> RegexpNode s r a -> Regexp s r b
    Fmap :: (a -> b) -> RegexpNode s r a -> Regexp s r b
    Rep :: (b -> a -> b) -- folding function (like in foldl)
        -> b             -- the value for zero matches, and also the initial value
                         -- for the folding function
        -> RegexpNode s (b, b -> r, PrNum, PrSeq) a
                         -- Elements for 4-tuple are: the value accumulated so far;
                         -- continuation; number of iterations for this instance
                         -- of Rep; and the priority that we had before entering
                         -- this instance of Rep
        -> Regexp s r b

data RegexpNode s r a = RegexpNode
    { active :: !Bool
    , empty  :: !(Priority a)
    , final_ :: !(Priority r)
    , reg    :: !(Regexp s r a)
    }

instance Functor (RE s) where
    fmap f (RE a) = RE $ fmapNode f a

instance Applicative (RE s) where
    pure x = const x <$> RE epsNode
    (RE a1) <*> (RE a2) = RE $ RegexpNode
        { active = False
        , empty = empty a1 <*> empty a2
        , final_ = zero
        , reg = App a1 a2
        }

instance Alternative (RE s) where
    (RE a1) <|> (RE a2) = RE $ RegexpNode
        { active = False
        , empty = empty a1 `emptyChoice` empty a2
        , final_ = zero
        , reg = Alt a1 a2
        }
    empty = error "noMatch" <$> psym (const False)
    many a = reverse <$> reFoldl (flip (:)) [] a

zero = Fail
isOK p =
    case p of
        Fail -> False
        Priority {} -> True
emptyChoice p@Priority {} _ = p
emptyChoice _ p = p

final r = if active r then final_ r else zero

epsNode :: RegexpNode s r a
epsNode = RegexpNode
    { active = False
    , empty  = pure $ error "epsNode"
    , final_ = zero
    , reg    = Eps
    }

symbolNode :: (s -> Bool) -> RegexpNode s r s
symbolNode c = RegexpNode
    { active = False
    , empty  = zero
    , final_ = zero
    , reg    = Symbol c
    }

altNode :: RegexpNode s r a -> RegexpNode s r a -> RegexpNode s r a
altNode a1 a2 = RegexpNode
    { active = active a1 || active a2
    , empty  = empty a1 `emptyChoice` empty a2
    , final_ = final a1 <|> final a2
    , reg    = Alt a1 a2
    }

appNode :: RegexpNode s (a -> r) (a -> b) -> RegexpNode s r a -> RegexpNode s r b
appNode a1 a2 = RegexpNode
    { active = active a1 || active a2
    , empty  = empty a1 <*> empty a2
    , final_ = final a1 <*> empty a2 <|> final a2
    , reg    = App a1 a2
    }

fmapNode :: (a -> b) -> RegexpNode s r a -> RegexpNode s r b
fmapNode f a = RegexpNode
    { active = active a
    , empty = fmap f $ empty a
    , final_ = final a
    , reg = Fmap f a
    }

repNode :: (b -> a -> b) -> b -> RegexpNode s (b, b -> r, PrNum, PrSeq) a -> RegexpNode s r b
repNode f b a = RegexpNode
    { active = active a
    , empty = withPriority 0 $ pure b
    , final_ = (\(b, f, _, _) -> f b) <$> final a
    , reg = Rep f b a
    }

shift :: Priority (a -> r) -> RegexpNode s r a -> s -> RegexpNode s r a
shift Fail r _ | not $ active r = r
shift k re s =
    case reg re of
        Eps -> re
        Symbol predicate ->
            let f = k <*> if predicate s then pure s else zero
            in re { final_ = f, active = isOK f }
        Alt a1 a2 -> altNode (shift (withPriority 1 k) a1 s) (shift (withPriority 0 k) a2 s)
        App a1 a2 -> appNode
            (shift kc a1 s)
            (shift (kc <*> empty a1 <|> final a1) a2 s)
            where kc = fmap (.) k
        Fmap f a -> fmapNode f $ shift (fmap (. f) k) a s
        Rep f b a -> repNode f b $ shift k' a s
            where
            k' =
                (\kk -> \a -> (f b a, kk, 1, priority k)) <$>
                    withPriority 1 k                    <|>
                (\(b, k, iters, pr) -> \a -> (f b a, k, iters, pr)) <$>
                    reprioritize (final a)

            reprioritize p =
                case p of
                    Fail -> Fail
                    Priority _ a@(b, k, iters, pr) ->
                        let iters' = iters+1
                            pr' = pr Sequence.|> iters'
                        in iters' `seq` Priority pr' (b, k, iters', pr)

match :: RegexpNode s r r -> [s] -> Priority r
match r [] = empty r
match r (s:ss) = final $
    foldl' (\r s -> shift zero r s) (shift (pure id) r s) ss

-- user interface
sym :: Eq s => s -> RE s s
sym s = psym (s ==)

psym :: (s -> Bool) -> RE s s
psym p = RE $ symbolNode p

anySym :: RE s s
anySym = psym (const True)

string :: Eq a => [a] -> RE a [a]
string = sequenceA . map sym

reFoldl :: (b -> a -> b) -> b -> RE s a -> RE s b
reFoldl f b (RE a) = RE $ RegexpNode
    { active = False
    , empty = pure b
    , final_ = zero
    , reg = Rep f b a
    }

s =~ (RE r) = priorityToMaybe $ match r s
