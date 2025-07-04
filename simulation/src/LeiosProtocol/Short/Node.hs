{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoFieldSelectors #-}

module LeiosProtocol.Short.Node where

import Chan
import Control.Category ((>>>))
import Control.Concurrent.Class.MonadMVar
import Control.Concurrent.Class.MonadSTM.TSem
import Control.Exception (assert)
import Control.Monad (forever, guard, replicateM, unless, when)
import Control.Monad.Class.MonadAsync
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadThrow
import Control.Tracer
import Data.Bifunctor
import Data.Coerce (coerce)
import Data.Foldable (Foldable (foldl'), forM_, for_)
import Data.Ix (Ix)
import Data.List (sortOn)
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Ord
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Traversable
import Data.Tuple (swap)
import LeiosProtocol.Common
import LeiosProtocol.Config
import LeiosProtocol.Relay
import qualified LeiosProtocol.RelayBuffer as RB
import LeiosProtocol.Short as Short
import LeiosProtocol.Short.Generate
import qualified LeiosProtocol.Short.Generate as Generate
import Numeric.Natural (Natural)
import PraosProtocol.BlockFetch (
  BlockFetchControllerState (blocksVar),
  addProducedBlock,
  processWaiting',
 )
import qualified PraosProtocol.Common.Chain as Chain
import qualified PraosProtocol.PraosNode as PraosNode
import STMCompat
import SimTypes (cpuTask)
import System.Random

--------------------------------------------------------------
---- Events
--------------------------------------------------------------

data LeiosEventBlock
  = EventIB !InputBlock
  | EventEB !EndorseBlock
  | EventVote !VoteMsg
  deriving (Show)

data BlockEvent
  = Generate
  | Received
  | EnterState
  | Pruned
  deriving (Show)

data ConformanceEvent
  = Slot {slot :: !SlotNo}
  | NoIBGenerated {slot :: !SlotNo}
  | NoEBGenerated {slot :: !SlotNo}
  | NoVTGenerated {slot :: !SlotNo}
  deriving (Show)

data LeiosNodeEvent
  = PraosNodeEvent !(PraosNode.PraosNodeEvent RankingBlockBody)
  | LeiosNodeEventCPU !CPUTask
  | LeiosNodeEvent !BlockEvent !LeiosEventBlock
  | LeiosNodeEventLedgerState !RankingBlockId
  | LeiosNodeEventConformance !ConformanceEvent
  deriving (Show)

--------------------------------------------------------------
---- Node Config
--------------------------------------------------------------

data BlockGeneration
  = Honest
  | UnboundedIbs
      { startingAtSlot :: SlotNo
      , slotOfGeneratedIbs :: SlotNo
      , ibsPerSlot :: Word64
      }

data LeiosNodeConfig = LeiosNodeConfig
  { leios :: !LeiosConfig
  , slotConfig :: !SlotConfig
  , nodeId :: !NodeId
  , stake :: !StakeFraction
  , rng :: !StdGen
  -- ^ for block generation
  , baseChain :: !(Chain RankingBlock)
  , processingQueueBound :: !Natural
  , processingCores :: !NumCores
  , blockGeneration :: !BlockGeneration
  , conformanceEvents :: !Bool
  }

--------------------------------------------------------------
---- Node State
--------------------------------------------------------------

data LeiosNodeState m = LeiosNodeState
  { praosState :: !(PraosNode.PraosNodeState RankingBlockBody m)
  , relayIBState :: !(RelayIBState m)
  -- ^ validated IBs that are still young enough to be diffusing
  , iBsForEBsAndVotesVar :: !(TVar m (Map PipelineNo (Map InputBlockId IbDeliveryStage)))
  -- ^ IBs that are relevant to an EB or Vote this node might need to issue
  --
  -- Each of these IBs arrived during its contemporary Propose, Deliver1,
  -- Deliver2, or Endorse stages, has been validated, and is not too old.
  --
  -- INVARIANT: In basic Short Leios, none of these IBs are older than
  -- @4*'sliceLength'@. With the @leios-late-ib-inclusion@ extension enabled,
  -- none of these IBs are older than @(4+2)*'sliceLength'@.
  --
  -- Note that some IBs that are too old to be included in this variable
  -- might still be needed in order to apply some RB.
  --
  -- INVARIANT: @all (\_k v -> not $ null v)@.
  --
  -- INVARIANT: @all (\k v -> all ((k ==) . pipelineOf cfg Propose) v)@.
  , relayEBState :: !(RelayEBState m)
  , prunedUnadoptedEBStateToVar :: !(TVar m SlotNo)
  , prunedUncertifiedEBStateToVar :: !(TVar m SlotNo)
  , relayVoteState :: !(RelayVoteState m)
  , prunedVoteStateToVar :: !(TVar m SlotNo)
  -- ^ TODO: refactor into RelayState.
  , taskQueue :: !(TaskMultiQueue LeiosNodeTask m)
  , waitingForRBVar :: !(TVar m (Map (HeaderHash RankingBlock) [STM m ()]))
  -- ^ waiting for RB block itself to be validated.
  , waitingForLedgerStateVar :: !(TVar m (Map (HeaderHash RankingBlock) [STM m ()]))
  -- ^ waiting for ledger state of RB block to be validated.
  , ledgerStateVar :: !(TVar m (Map (HeaderHash RankingBlock) LedgerState))
  , ibsNeededForEBVar :: !(TVar m (Map EndorseBlockId (Set InputBlockId)))
  , ibsValidationActionsVar :: !(TVar m (Map InputBlockId (STM m ())))
  , votesForEBVar :: !(TVar m (Map EndorseBlockId CertificateProgress))
  }

type CertificatesProgress = Map EndorseBlockId CertificateProgress
data CertificateProgress
  = Certified {cert :: !Certificate, certTime :: !UTCTime}
  | AccumulatingVotes {votesSoFar :: !(Map VoteId Word64)}

addVote :: LeiosConfig -> VoteMsg -> UTCTime -> CertificatesProgress -> CertificatesProgress
addVote leios vt time m0 =
  foldl' (\m eb -> Map.alter aux eb m) m0 vt.endorseBlocks
 where
  aux (Just x@Certified{}) = Just x
  aux (Just AccumulatingVotes{..}) = Just $ checkIfCertified $ (Map.insert vt.id vt.votes votesSoFar)
  aux Nothing = Just $ checkIfCertified (Map.singleton vt.id vt.votes)

  checkIfCertified :: Map VoteId Word64 -> CertificateProgress
  checkIfCertified votesSoFar
    | (fromIntegral . sum . Map.elems) votesSoFar >= leios.votesForCertificate =
        Certified (mkCertificate leios votesSoFar) time
    | otherwise = AccumulatingVotes votesSoFar

data LeiosNodeTask
  = ValIB
  | ValEB
  | ValVote
  | ValRB
  | ValIH
  | ValRH
  | GenIB
  | GenEB
  | GenVote
  | GenRB
  deriving (Eq, Ord, Ix, Bounded, Show)

data NodeRelayState id header body m = NodeRelayState
  { relayBufferVar :: !(TVar m (RB.RelayBuffer id (header, body)))
  }
type RelayIBState = NodeRelayState InputBlockId InputBlockHeader InputBlockBody
type RelayEBState = NodeRelayState EndorseBlockId (RelayHeader EndorseBlockId) EndorseBlock
type RelayVoteState = NodeRelayState VoteId (RelayHeader VoteId) VoteMsg

data LedgerState = LedgerState

data ValidationRequest m
  = ValidateRB !RankingBlock !(m ())
  | ValidateIBs ![((InputBlockHeader, InputBlockBody), IbDeliveryStage)] !([(InputBlockHeader, InputBlockBody)] -> STM m ())
  | ValidateEBS ![EndorseBlock] !([EndorseBlock] -> STM m ())
  | ValidateVotes ![VoteMsg] !UTCTime !([VoteMsg] -> STM m ())

--------------------------------------------------------------
--- Messages
--------------------------------------------------------------

data RelayHeader id = RelayHeader {id :: !id, slot :: !SlotNo}
  deriving (Show)

instance MessageSize id => MessageSize (RelayHeader id) where
  messageSizeBytes (RelayHeader x y) = messageSizeBytes x + messageSizeBytes y

type RelayIBMessage = RelayMessage InputBlockId InputBlockHeader InputBlockBody
type RelayEBMessage = RelayMessage EndorseBlockId (RelayHeader EndorseBlockId) EndorseBlock
type RelayVoteMessage = RelayMessage VoteId (RelayHeader VoteId) VoteMsg
type PraosMessage = PraosNode.PraosMessage RankingBlockBody

data LeiosMessage
  = RelayIB {fromRelayIB :: !RelayIBMessage}
  | RelayEB {fromRelayEB :: !RelayEBMessage}
  | RelayVote {fromRelayVote :: !RelayVoteMessage}
  | PraosMsg {fromPraosMsg :: !PraosMessage}
  deriving (Show)

data Leios f = Leios
  { protocolIB :: f RelayIBMessage
  , protocolEB :: f RelayEBMessage
  , protocolVote :: f RelayVoteMessage
  , protocolPraos :: PraosNode.Praos RankingBlockBody f
  }

instance MessageSize LeiosMessage where
  messageSizeBytes lm = case lm of
    RelayIB m -> messageSizeBytes m
    RelayEB m -> messageSizeBytes m
    RelayVote m -> messageSizeBytes m
    PraosMsg m -> messageSizeBytes m

instance ConnectionBundle Leios where
  type BundleMsg Leios = LeiosMessage
  type BundleConstraint Leios = MessageSize
  toFromBundleMsgBundle =
    Leios
      { protocolIB = ToFromBundleMsg RelayIB (.fromRelayIB)
      , protocolEB = ToFromBundleMsg RelayEB (.fromRelayEB)
      , protocolVote = ToFromBundleMsg RelayVote (.fromRelayVote)
      , protocolPraos = case toFromBundleMsgBundle @(PraosNode.Praos RankingBlockBody) of
          PraosNode.Praos a b -> PraosNode.Praos (p >>> a) (p >>> b)
      }
   where
    p = ToFromBundleMsg PraosMsg (.fromPraosMsg)

  traverseConnectionBundle f (Leios a b c d) = Leios <$> f a <*> f b <*> f c <*> traverseConnectionBundle f d

--------------------------------------------------------------

newRelayState ::
  (Ord id, MonadSTM m) =>
  m (NodeRelayState id header body m)
newRelayState = do
  relayBufferVar <- newTVarIO RB.empty
  return $ NodeRelayState{relayBufferVar}

setupRelay ::
  (Ord id, MonadAsync m, MonadSTM m, MonadDelay m, MonadTime m) =>
  LeiosConfig ->
  RelayConsumerConfig id header body m ->
  NodeRelayState id header body m ->
  [Chan m (RelayMessage id header body)] ->
  [Chan m (RelayMessage id header body)] ->
  m [m ()]
setupRelay leiosConfig cfg st followers peers = do
  let producerSST = RelayProducerSharedState{relayBufferVar = asReadOnly st.relayBufferVar}
  ssts <- do
    case leiosConfig.relayStrategy of
      RequestFromFirst -> do
        inFlightVar <- newTVarIO Set.empty
        return $ repeat $ RelayConsumerSharedState{relayBufferVar = st.relayBufferVar, inFlightVar}
      RequestFromAll -> do
        (fmap . fmap) (RelayConsumerSharedState st.relayBufferVar) . replicateM (length peers) $ newTVarIO Set.empty
  let consumers = map (uncurry $ runRelayConsumer cfg) (zip ssts peers)
  let producers = map (runRelayProducer cfg.relay producerSST) followers
  return $ consumers ++ producers

type SubmitBlocks m header body =
  [(header, body)] ->
  UTCTime ->
  ([(header, body)] -> STM m ()) ->
  m ()

relayIBConfig ::
  (MonadAsync m, MonadSTM m, MonadDelay m, MonadTime m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  ([InputBlockHeader] -> m ()) ->
  SubmitBlocks m InputBlockHeader InputBlockBody ->
  LeiosNodeState m ->
  RelayConsumerConfig InputBlockId InputBlockHeader InputBlockBody m
relayIBConfig _tracer cfg validateHeaders submitBlocks st =
  RelayConsumerConfig
    { relay = RelayConfig{maxWindowSize = coerce cfg.leios.ibDiffusion.maxWindowSize}
    , headerId = (.id)
    , validateHeaders
    , prioritize = prioritize cfg.leios.ibDiffusion.strategy (.slot)
    , submitPolicy = SubmitAll
    , maxHeadersToRequest = cfg.leios.ibDiffusion.maxHeadersToRequest
    , maxBodiesToRequest = cfg.leios.ibDiffusion.maxBodiesToRequest
    , submitBlocks
    , shouldNotRequest = (getCurrentTime >>=) $ \deliveryTime -> atomically $ do
        let late h = ibWasDeliveredLate cfg.leios cfg.slotConfig h.slot deliveryTime
        buff <- readTVar st.relayIBState.relayBufferVar
        return $ \h -> late h || h.id `RB.member` buff
    }

relayEBConfig ::
  (MonadTime m, MonadDelay m, MonadSTM m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  SubmitBlocks m EndorseBlockId EndorseBlock ->
  RelayEBState m ->
  LeiosNodeState m ->
  RelayConsumerConfig EndorseBlockId (RelayHeader EndorseBlockId) EndorseBlock m
relayEBConfig _tracer cfg@LeiosNodeConfig{leios = LeiosConfig{pipeline = (_ :: SingPipeline p)}} submitBlocks st leiosState =
  RelayConsumerConfig
    { relay = RelayConfig{maxWindowSize = coerce cfg.leios.ebDiffusion.maxWindowSize}
    , headerId = (.id)
    , validateHeaders = const $ return ()
    , prioritize = prioritize cfg.leios.ebDiffusion.strategy (.slot)
    , submitPolicy = SubmitAll
    , maxHeadersToRequest = cfg.leios.ebDiffusion.maxHeadersToRequest
    , maxBodiesToRequest = cfg.leios.ebDiffusion.maxBodiesToRequest
    , submitBlocks = \hbs t k ->
        submitBlocks (map (first (.id)) hbs) t (k . map (\(i, b) -> (RelayHeader i b.slot, b)))
    , shouldNotRequest = do
        -- We possibly prune certified EBs (not referenced in the
        -- chain) after maxEndorseBlockAgeSlots, so we should not end
        -- up asking for their bodies again, in the remote possibility
        -- they get offered.
        assert (cfg.leios.maxEndorseBlockAgeForRelaySlots <= cfg.leios.maxEndorseBlockAgeSlots) $ do
          currSlot <- currentSlotNo cfg.slotConfig
          let oldestEBToRelay = currSlot - fromIntegral cfg.leios.maxEndorseBlockAgeForRelaySlots
          atomically $ do
            ebBuffer <- readTVar st.relayBufferVar
            prunedTo <- readTVar leiosState.prunedUncertifiedEBStateToVar
            pure $ \ebHeader -> do
              -- Check whether or not the EB is older than prunedUncertifiedEBStateTo
              -- Should be redundant with check against oldestEBToRelay: only EBs from previous pipeline are pruned this way.
              let ebTooOld1 = ebHeader.slot < prunedTo
              -- Check whether or not the EB is older than "eb-max-age-for-relay-slots"
              let ebTooOld2 = ebHeader.slot < oldestEBToRelay
              -- Check whether or not the EB is already in the relay buffer
              let ebAlreadyInBuffer = RB.member ebHeader.id ebBuffer
              ebTooOld1 || ebTooOld2 || ebAlreadyInBuffer
    }

relayVoteConfig ::
  (MonadDelay m, Monad (STM m), MonadSTM m, MonadTime m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  SubmitBlocks m VoteId VoteMsg ->
  RelayVoteState m ->
  LeiosNodeState m ->
  RelayConsumerConfig VoteId (RelayHeader VoteId) VoteMsg m
relayVoteConfig _tracer cfg submitBlocks _ leiosState =
  RelayConsumerConfig
    { relay = RelayConfig{maxWindowSize = coerce cfg.leios.voteDiffusion.maxWindowSize}
    , headerId = (.id)
    , validateHeaders = const $ return ()
    , prioritize = prioritize cfg.leios.voteDiffusion.strategy (.slot)
    , submitPolicy = SubmitAll
    , maxHeadersToRequest = cfg.leios.voteDiffusion.maxHeadersToRequest
    , maxBodiesToRequest = cfg.leios.voteDiffusion.maxBodiesToRequest
    , submitBlocks = \hbs t k ->
        submitBlocks (map (first (.id)) hbs) t (k . map (\(i, b) -> (RelayHeader i b.slot, b)))
    , shouldNotRequest = atomically $ do
        buffer <- readTVar leiosState.relayVoteState.relayBufferVar
        prunedTo <- readTVar leiosState.prunedVoteStateToVar
        return $ \hd ->
          hd.slot < prunedTo
            || hd.id `RB.member` buffer
    }

queueAndWait :: (MonadSTM m, MonadDelay m) => LeiosNodeState m -> LeiosNodeTask -> [CPUTask] -> m ()
queueAndWait _st _lbl [] = return ()
queueAndWait st lbl ds = do
  let l = fromIntegral $ length ds
  sem <- atomically $ do
    sem <- newTSem (1 - l)
    forM_ ds $ \task -> do
      writeTMQueue st.taskQueue lbl (task, atomically $ signalTSem sem)
    return sem
  atomically $ waitTSem sem

newLeiosNodeState ::
  forall m.
  (MonadMVar m, MonadSTM m) =>
  LeiosNodeConfig ->
  m (LeiosNodeState m)
newLeiosNodeState cfg = do
  praosState <- PraosNode.newPraosNodeState cfg.baseChain
  relayIBState <- newRelayState
  iBsForEBsAndVotesVar <- newTVarIO Map.empty
  relayEBState <- newRelayState
  prunedUnadoptedEBStateToVar <- newTVarIO (toEnum 0)
  prunedUncertifiedEBStateToVar <- newTVarIO (toEnum 0)
  relayVoteState <- newRelayState
  prunedVoteStateToVar <- newTVarIO (toEnum 0)
  ibsNeededForEBVar <- newTVarIO Map.empty
  ledgerStateVar <- newTVarIO Map.empty
  waitingForRBVar <- newTVarIO Map.empty
  waitingForLedgerStateVar <- newTVarIO Map.empty
  taskQueue <- atomically $ newTaskMultiQueue cfg.processingQueueBound
  votesForEBVar <- newTVarIO Map.empty
  ibsValidationActionsVar <- newTVarIO Map.empty
  return $ LeiosNodeState{..}

leiosNode ::
  forall m.
  ( MonadMVar m
  , MonadFork m
  , MonadAsync m
  , MonadSTM m
  , MonadTime m
  , MonadDelay m
  , MonadMonotonicTimeNSec m
  , MonadCatch m
  ) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  [Leios (Chan m)] ->
  [Leios (Chan m)] ->
  m [m ()]
leiosNode tracer cfg followers peers = do
  leiosState@LeiosNodeState{..} <- newLeiosNodeState cfg
  let
    traceReceived :: [a] -> (a -> LeiosEventBlock) -> m ()
    traceReceived xs f = mapM_ (traceWith tracer . LeiosNodeEvent Received . f) xs

  let dispatch = dispatchValidation tracer cfg leiosState
  -- tracing for RB already covered in blockFetchConsumer.
  let submitRB rb completion = dispatch $! ValidateRB rb completion
  let submitIB xs deliveryTime completion = do
        traceReceived xs $ EventIB . uncurry InputBlock
        let annotate x = (,) x <$> ibDeliveryStage cfg.leios cfg.slotConfig (fst x).slot deliveryTime
        let xs' = mapMaybe annotate xs -- TODO what to do with early/late arrivals?
        unless (null xs') $ dispatch $! ValidateIBs xs' completion
  let submitVote (map snd -> xs) deliveryTime completion = do
        traceReceived xs EventVote
        dispatch $! ValidateVotes xs deliveryTime $ completion . map (\v -> (v.id, v))
  let submitEB (map snd -> xs) _ completion = do
        traceReceived xs EventEB
        dispatch $! ValidateEBS xs $ completion . map (\eb -> (eb.id, eb))
  let valHeaderIB =
        queueAndWait leiosState ValIH . map (cpuTask "ValIH" cfg.leios.delays.inputBlockHeaderValidation)
  let valHeaderRB h = do
        let !task = cpuTask "ValRH" cfg.leios.praos.headerValidationDelay h
        queueAndWait leiosState ValRH [task]

  praosThreads <-
    PraosNode.setupPraosThreads'
      (contramap PraosNodeEvent tracer)
      cfg.leios.praos
      valHeaderRB
      submitRB
      praosState
      (map (.protocolPraos) followers)
      (map (.protocolPraos) peers)

  ibThreads <-
    setupRelay
      cfg.leios
      (relayIBConfig tracer cfg valHeaderIB submitIB leiosState)
      relayIBState
      (map (.protocolIB) followers)
      (map (.protocolIB) peers)

  ebThreads <-
    setupRelay
      cfg.leios
      (relayEBConfig tracer cfg submitEB relayEBState leiosState)
      relayEBState
      (map (.protocolEB) followers)
      (map (.protocolEB) peers)

  voteThreads <-
    setupRelay
      cfg.leios
      (relayVoteConfig tracer cfg submitVote relayVoteState leiosState)
      relayVoteState
      (map (.protocolVote) followers)
      (map (.protocolVote) peers)

  let processWaitingForRB =
        processWaiting'
          praosState.blockFetchControllerState.blocksVar
          waitingForRBVar

  let processWaitingForLedgerState =
        processWaiting'
          ledgerStateVar
          waitingForLedgerStateVar

  let processingThreads =
        [ processCPUTasks cfg.processingCores (contramap LeiosNodeEventCPU tracer) leiosState.taskQueue
        , processWaitingForRB
        , processWaitingForLedgerState
        ]

  let blockGenerationThreads = [generator tracer cfg leiosState]

  let computeLedgerStateThreads =
        [ computeLedgerStateThread tracer cfg leiosState
        -- , validateIBsOfCertifiedEBs tracer cfg leiosState
        ]

  let pruningThreads =
        concat
          [ [ pruneExpiredVotes tracer cfg leiosState
            | CleanupExpiredVote `isEnabledIn` cfg.leios.cleanupPolicies
            ]
          , [ pruneExpiredUncertifiedEBs tracer cfg leiosState
            | CleanupExpiredUncertifiedEb `isEnabledIn` cfg.leios.cleanupPolicies
            ]
          , [ pruneExpiredUnadoptedEBs tracer cfg leiosState
            | CleanupExpiredUnadoptedEb `isEnabledIn` cfg.leios.cleanupPolicies
            , -- With Full a fresh EB might end up referencing all the way to Genesis.
            -- TODO: could expire EBs not referenced by young enough EBs.
            cfg.leios.variant /= Full
            ]
          , [ pruneRelayIBState tracer cfg leiosState
            | CleanupExpiredIb `isEnabledIn` cfg.leios.cleanupPolicies
            ]
          , [ pruneIBsForEBsAndVotesVar tracer cfg leiosState
            | CleanupExpiredIb `isEnabledIn` cfg.leios.cleanupPolicies
            ]
          ]

  return $
    concat
      [ processingThreads
      , blockGenerationThreads
      , ibThreads
      , ebThreads
      , voteThreads
      , coerce praosThreads
      , computeLedgerStateThreads
      , pruningThreads
      ]

-- Prunes 'relayIBState'
pruneRelayIBState :: (Monad m, MonadDelay m, MonadSTM m, MonadTime m) => Tracer m LeiosNodeEvent -> LeiosNodeConfig -> LeiosNodeState m -> m ()
pruneRelayIBState _tracer LeiosNodeConfig{leios, slotConfig} st = go (toEnum 0)
 where
  go p = do
    let expiry = succ $ lastEndorse leios p
    let pruneTo = succ $ snd $ proposeRange leios p
    _ <- waitNextSlot slotConfig expiry
    _ibsPruned <- atomically $ do
      partitionRBVar st.relayIBState.relayBufferVar $
        \ibEntry -> (fst ibEntry.value).slot < pruneTo
    -- TODO: batch these, too many events
    -- for_ ibsPruned $ \(uncurry InputBlock -> ib) ->
    --   traceWith tracer $! LeiosNodeEvent Pruned (EventIB ib)
    go (succ p)

pruneIBsForEBsAndVotesVar :: (Monad m, MonadDelay m, MonadSTM m, MonadTime m) => Tracer m LeiosNodeEvent -> LeiosNodeConfig -> LeiosNodeState m -> m ()
pruneIBsForEBsAndVotesVar _tracer LeiosNodeConfig{leios, slotConfig} st = go (toEnum 0)
 where
  go p = do
    let expiry = succ $ lastVoteSend leios $ (if leios.lateIbInclusion then succ . succ else id) $ p
    _ <- waitNextSlot slotConfig expiry
    _ibsPruned <- atomically $ do
      modifyTVar'
        st.iBsForEBsAndVotesVar
        (snd . Map.split p)
    -- TODO Pruned events
    go (succ p)

-- rEB slots after the end of Endorse,
-- prune EBs that became certified but were not adopted by an RB.
pruneExpiredUnadoptedEBs ::
  forall m.
  (Monad m, MonadDelay m, MonadTime m, MonadSTM m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  LeiosNodeState m ->
  m ()
pruneExpiredUnadoptedEBs tracer LeiosNodeConfig{leios, slotConfig} st = go (toEnum 0)
 where
  go :: PipelineNo -> m ()
  go p = do
    let ebRange@(endorseStart, endorseEnd) = endorseRange leios p
    let slotWhenEBsTooOldForRBs = succ $ endorseEnd + fromIntegral leios.maxEndorseBlockAgeSlots
    let pruneTo = succ endorseEnd
    _ <- waitNextSlot slotConfig slotWhenEBsTooOldForRBs
    chain <- atomically $ PraosNode.preferredChain st.praosState
    let rbsOnChain = takeWhile (\rb -> rb.blockHeader.headerSlot > endorseStart) . Chain.toNewestFirst $ chain
    let ebIdsOnChain =
          Set.fromList
            [ ebId
            | rb <- rbsOnChain
            , (ebId, _certificate) <- rb.blockBody.endorseBlocks
            ]
    ebsPruned <-
      atomically $ do
        -- Prune st.relayEBState.relayBufferVar for *certified* EBs in the current pipeline
        -- which were not adopted as part of the chain, and return the set of pruned EBs:
        ebsPruned <-
          (fmap . fmap) snd . partitionRBVar st.relayEBState.relayBufferVar $
            \ebEntry -> do
              let ebId = (snd ebEntry.value).id
              let ebSlot = (fst ebEntry.value).slot
              let ebInPipeline = ebSlot `inRange` ebRange
              let ebAdopted = ebId `Set.member` ebIdsOnChain
              -- NOTE: pruneExpiredUnadoptedEBs runs long after pruneExpiredUncertifiedEBs,
              --       hence any EB from pipeline p MUST be certified at this point
              ebInPipeline && not ebAdopted
        -- Create set of EB ids to prune:
        let ebIdsToPrune = Set.fromList [eb.id | eb <- ebsPruned]
        -- Prune st.votesForEBVar for *certified* EBs in ebIdsToPrune:
        modifyTVar' st.votesForEBVar (`Map.withoutKeys` ebIdsToPrune)
        -- Prune st.ibsNeededForEBVar for *certified* EBs in ebIdsToPrune:
        modifyTVar' st.ibsNeededForEBVar (`Map.withoutKeys` ebIdsToPrune)
        -- Update st.prunedUnadoptedEBStateToVar with the slot number pruned to.
        -- TODO: Unused
        writeTVar st.prunedUnadoptedEBStateToVar $! pruneTo
        -- Return the pruned EBs.
        pure ebsPruned
    -- Emit trace events for pruning each EB
    for_ ebsPruned $ \eb -> do
      traceWith tracer $! LeiosNodeEvent Pruned (EventEB eb)
    -- Continue with the next pipeline.
    go (succ p)

-- One slot after the end of vote-receiving,
-- prune all EBs that did not become certified within their pipeline.
pruneExpiredUncertifiedEBs ::
  forall m.
  (Monad m, MonadDelay m, MonadTime m, MonadSTM m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  LeiosNodeState m ->
  m ()
pruneExpiredUncertifiedEBs tracer LeiosNodeConfig{leios, slotConfig} st = go (toEnum 0)
 where
  go :: PipelineNo -> m ()
  go p = do
    let (_, endorseEnd) = endorseRange leios p
    let endOfVoting = succ (lastVoteRecv leios p)
    let pruneTo = succ endorseEnd
    _ <- waitNextSlot slotConfig endOfVoting
    ebsPruned <-
      atomically $ do
        votesForEB <- readTVar st.votesForEBVar
        -- Prune st.relayEBState.relayBufferVar for EBs in pipeline p that did not become certified.
        ebsPruned <- (fmap . fmap) snd . partitionRBVar st.relayEBState.relayBufferVar $
          \ebEntry -> do
            let ebId = (fst ebEntry.value).id
            let ebSlot = (fst ebEntry.value).slot
            let ebAlreadyVotedOn = ebSlot < pruneTo
            let ebCertified
                  | Just Certified{} <- Map.lookup ebId votesForEB =
                      True
                  | otherwise = False
            ebAlreadyVotedOn && not ebCertified
        -- Create set of EB ids to prune:
        let ebIdsToPrune = Set.fromList [eb.id | eb <- ebsPruned]
        -- Prune st.votesForEBVar for uncertified EBs in ebIdsToPrune:
        modifyTVar' st.votesForEBVar (`Map.withoutKeys` ebIdsToPrune)
        -- Prune st.ibsNeededForEBVar for uncertified EBs in ebIdsToPrune:
        modifyTVar' st.ibsNeededForEBVar (`Map.withoutKeys` ebIdsToPrune)
        -- Update st.prunedUncertifiedEBStateToVar with the slot number pruned to.
        writeTVar st.prunedUncertifiedEBStateToVar $! pruneTo
        -- Return the pruned EBs.
        pure ebsPruned
    -- Emit trace events for pruning each EB
    for_ ebsPruned $ \eb -> do
      traceWith tracer $! LeiosNodeEvent Pruned (EventEB eb)
    -- Continue with the next pipeline.
    go (succ p)

-- One slot after the end of vote-receiving,
-- prune all votes from before the last vote-sending slot.
pruneExpiredVotes ::
  (Monad m, MonadDelay m, MonadTime m, MonadSTM m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  LeiosNodeState m ->
  m ()
pruneExpiredVotes _tracer LeiosNodeConfig{leios = leios@LeiosConfig{pipeline = _ :: SingPipeline p}, slotConfig} st = go (toEnum 0)
 where
  go p = do
    let pruneTo = succ (lastVoteSend leios p)
    _ <- waitNextSlot slotConfig (succ (lastVoteRecv leios p))
    _votesPruned <- atomically $ do
      writeTVar st.prunedVoteStateToVar $! pruneTo
      partitionRBVar st.relayVoteState.relayBufferVar $
        \voteEntry ->
          let voteSlot = (snd voteEntry.value).slot
           in voteSlot < pruneTo
    -- TODO: batch these, too many events.
    -- for_ votesPruned $ \vt -> do
    --   traceWith tracer $! LeiosNodeEvent Pruned (EventVote $ snd vt)
    go (succ p)

referencedEBs :: MonadSTM m => LeiosConfig -> LeiosNodeState m -> Set EndorseBlockId -> STM m [EndorseBlockId]
referencedEBs cfg st ebIds0
  | null ebIds0 = return []
  | Short <- cfg.variant = pure $ Set.toList ebIds0
  | otherwise = do
      ebBuffer <- readTVar st.relayEBState.relayBufferVar
      let
        ebsReferenced :: Set EndorseBlockId -> Set EndorseBlockId -> [EndorseBlockId]
        ebsReferenced !fetched ebIds
          | null ebIds = []
          | otherwise = do
              let ebs =
                    [ snd $ fromMaybe (error $ "EB missing:" ++ show ebId) $ RB.lookup ebBuffer ebId
                    | ebId <- Set.toList ebIds
                    ]
              let fetched' = Set.union fetched ebIds
              let refs =
                    Set.fromList
                      [ refId
                      | eb <- ebs
                      , refId <- eb.endorseBlocksEarlierPipeline
                      , Set.notMember refId fetched'
                      ]
              map (.id) ebs ++ ebsReferenced fetched' refs
      return $ ebsReferenced Set.empty ebIds0

computeLedgerStateThread ::
  forall m.
  (MonadMVar m, MonadFork m, MonadAsync m, MonadSTM m, MonadTime m, MonadDelay m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  LeiosNodeState m ->
  m ()
computeLedgerStateThread tracer cfg st = forever $ do
  readyLedgerState <- atomically $ do
    -- TODO: this will get more costly as the base chain grows,
    -- however it grows much more slowly than anything else.
    chain <- PraosNode.preferredChain st.praosState
    let rbsOnChain = Chain.toNewestFirst $ chain
    when (null rbsOnChain) retry
    -- TODO: should we prune the ledger state to only cover RBs on the chain?
    ledgerState <- readTVar st.ledgerStateVar
    let oldestMissingLedgerState = go Nothing rbsOnChain
         where
          go acc [] = acc
          go acc (x : xs)
            | Map.member (blockHash x) ledgerState = acc
            | otherwise = go (Just x) xs
    ledgerEligible <- case oldestMissingLedgerState of
      Nothing -> retry
      Just block -> pure block

    todo <- do
      let doLedgerState = Left (blockHash ledgerEligible, LedgerState)
      case (map fst $ ledgerEligible.blockBody.endorseBlocks) of
        [] -> return $ doLedgerState
        ebIds -> do
          ibsNeededForEB <- readTVar st.ibsNeededForEBVar
          ibsNeeded <- do
            ebs <- referencedEBs cfg.leios st (Set.fromList ebIds)
            return $ Set.unions <$> mapM (flip Map.lookup ibsNeededForEB) ebs
          case ibsNeeded of
            -- Some EB was missing ibsNeeded info
            Nothing -> undefined
            Just ibs
              | Set.null ibs -> pure $ doLedgerState
              | otherwise -> pure $ Right ibs

    case todo of
      Left readyLedgerState -> do
        modifyTVar' st.ledgerStateVar (uncurry Map.insert readyLedgerState)
        return [readyLedgerState]
      Right ibsEligibleToValidate -> do
        ibValActions <- readTVar st.ibsValidationActionsVar
        let ibsReadyToValidate = Map.elems $ Map.restrictKeys ibValActions ibsEligibleToValidate
        if null ibsReadyToValidate
          then retry
          else do
            modifyTVar' st.ibsValidationActionsVar $ flip Map.withoutKeys ibsEligibleToValidate
            sequence_ ibsReadyToValidate
            return []
  for_ readyLedgerState $ \(rb, _) -> do
    traceWith tracer $! LeiosNodeEventLedgerState rb
  return ()

-- TODO: Use or remove.
--       Might be sensible to validate IBs as soon as we have a certified EB including them: the network managed to validate the IB, so a suitable ledger state is available.
validateIBsOfCertifiedEBs :: MonadSTM m => Tracer m LeiosNodeEvent -> LeiosNodeConfig -> LeiosNodeState m -> m ()
validateIBsOfCertifiedEBs _trace _cfg st = forever . atomically $ do
  ibsNeeded <- readTVar st.ibsNeededForEBVar
  ebs <- readTVar st.votesForEBVar
  let certEBs = Set.fromList [eb | (eb, Certified{}) <- Map.toList ebs]
  let ibsEligible = Set.unions $ Map.elems $ Map.restrictKeys ibsNeeded certEBs
  when (null ibsEligible) retry
  ibsValActions <- readTVar st.ibsValidationActionsVar
  let ibsToValidate = Map.toList $ Map.restrictKeys ibsValActions ibsEligible
  when (null ibsToValidate) $ retry
  forM_ ibsToValidate $ \(ibId, m) -> do
    modifyTVar' st.ibsValidationActionsVar $ Map.delete ibId
    m

-- | This is called once the IB has been validated
--
-- An IB might be validated a long while after it arrived.
--
-- An IB that arrived later than it should have will not even be validated.
adoptIB :: MonadSTM m => LeiosConfig -> LeiosNodeState m -> InputBlock -> IbDeliveryStage -> STM m ()
adoptIB cfg leiosState ib deliveryStage = do
  let !ibSlot = ib.header.slot
      !p = case cfg of
        LeiosConfig{pipeline = _ :: SingPipeline p} ->
          pipelineOf @p cfg Short.Propose ibSlot
  modifyTVar'
    leiosState.iBsForEBsAndVotesVar
    (Map.insertWith (Map.unionWith min) p $ Map.singleton ib.id deliveryStage)

  -- TODO: likely needs optimization, although EBs also grow slowly.
  modifyTVar' leiosState.ibsNeededForEBVar (Map.map (Set.delete ib.id))

adoptEB :: MonadSTM m => LeiosNodeState m -> EndorseBlock -> STM m ()
adoptEB leiosState eb = do
  ibs <- Set.unions . Map.map Map.keysSet <$> readTVar leiosState.iBsForEBsAndVotesVar
  let ibsNeeded = Map.fromList [(eb.id, Set.fromList eb.inputBlocks Set.\\ ibs)]
  modifyTVar' leiosState.ibsNeededForEBVar (`Map.union` ibsNeeded)

adoptVote :: MonadSTM m => LeiosConfig -> LeiosNodeState m -> VoteMsg -> UTCTime -> STM m ()
adoptVote leios leiosState v deliveryTime = do
  -- We keep tally for each EB as votes arrive, so the relayVoteBuffer
  -- can be pruned without effects on EB certification.
  modifyTVar' leiosState.votesForEBVar $ addVote leios v deliveryTime

dispatchValidation ::
  forall m.
  (MonadMVar m, MonadFork m, MonadAsync m, MonadSTM m, MonadTime m, MonadDelay m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  LeiosNodeState m ->
  ValidationRequest m ->
  m ()
dispatchValidation tracer cfg leiosState req =
  atomically $ queue =<< go req
 where
  queue = mapM_ (uncurry $ writeTMQueue leiosState.taskQueue)
  labelTask (tag, (f, m)) = let !task = f (show tag) in (tag, (task, m))
  valRB rb m = do
    let task prefix = cpuTask prefix cfg.leios.praos.blockValidationDelay rb
    labelTask (ValRB, (task, m))
  valIB x@(uncurry InputBlock -> ib) deliveryStage completion =
    let
      delay prefix = cpuTask prefix cfg.leios.delays.inputBlockValidation ib
      task = atomically $ do
        completion [x]
        adoptIB cfg.leios leiosState ib deliveryStage
     in
      labelTask (ValIB, (delay, task >> traceEnterState [uncurry InputBlock x] EventIB))
  valEB eb completion = labelTask . (ValEB,) . (\p -> cpuTask p cfg.leios.delays.endorseBlockValidation eb,) $ do
    atomically $ do
      completion [eb]
      adoptEB leiosState eb
    traceEnterState [eb] EventEB
  valVote v deliveryTime completion = labelTask . (ValVote,) . (\p -> cpuTask p cfg.leios.delays.voteMsgValidation v,) $ do
    atomically $ do
      completion [v]
      adoptVote cfg.leios leiosState v deliveryTime
    traceEnterState [v] EventVote

  go :: ValidationRequest m -> STM m [(LeiosNodeTask, (CPUTask, m ()))]
  go x = case x of
    ValidateRB rb completion -> do
      let task = valRB rb completion
      case blockPrevHash rb of
        GenesisHash -> do
          return [task]
        BlockHash prev -> do
          let var =
                assert (rb.blockBody.payload >= 0) $
                  if rb.blockBody.payload == 0
                    then leiosState.waitingForRBVar
                    -- TODO: assumes payload can be validated without content of EB, check with spec.
                    else leiosState.waitingForLedgerStateVar
          waitFor var [(prev, [queue [task]])]
          return []
    ValidateIBs ibs completion -> do
      -- NOTE: IBs with an RB reference have to wait for ledger state of that RB.
      --       However, if they get referenced by the chain they should be validated anyway.
      --       We use a map to store the validation logic, so we can force it happening in the latter case.
      let lookupValAction ibId = do
            ibValActions <- readTVar leiosState.ibsValidationActionsVar
            case Map.lookup ibId ibValActions of
              Just m -> do
                modifyTVar' leiosState.ibsValidationActionsVar $
                  Map.delete ibId
                m
              Nothing -> pure ()
      let storeAction rbHash ib@(h, _) deliveryStage = do
            modifyTVar' leiosState.ibsValidationActionsVar $
              Map.insert h.id (queue [valIB ib deliveryStage completion])
            return (rbHash, [lookupValAction $ (fst ib).id])
      waitingLedgerState <-
        sequence $
          [ storeAction rbHash ib deliveryStage
          | (ib, deliveryStage) <- ibs
          , BlockHash rbHash <- [(fst ib).rankingBlock]
          ]

      -- TODO: cancel the ones forced by computeLedgerState
      waitFor
        leiosState.waitingForLedgerStateVar
        waitingLedgerState

      return [valIB ib deliveryStage completion | (ib@(h, _), deliveryStage) <- ibs, GenesisHash <- [h.rankingBlock]]
    ValidateEBS ebs completion -> do
      -- NOTE: block references are only inspected during voting.
      return [valEB eb completion | eb <- ebs]
    ValidateVotes vs deliveryTime completion -> do
      return [valVote v deliveryTime completion | v <- vs]
  traceEnterState :: [a] -> (a -> LeiosEventBlock) -> m ()
  traceEnterState xs f = forM_ xs $ traceWith tracer . LeiosNodeEvent EnterState . f

generator ::
  forall m.
  (MonadMVar m, MonadFork m, MonadAsync m, MonadSTM m, MonadTime m, MonadDelay m) =>
  Tracer m LeiosNodeEvent ->
  LeiosNodeConfig ->
  LeiosNodeState m ->
  m ()
generator tracer cfg st = do
  schedule <- mkSchedule tracer cfg
  let buffers = mkBuffersView cfg st
  let
    withDelay d (lbl, m) = do
      -- cannot print id of generated RB until after it's generated,
      -- the id of the generated block can be found in the generated event emitted at the time the task ends.
      let !c = CPUTask d (T.pack $ show lbl)
      atomically $ writeTMQueue st.taskQueue lbl (c, m)
  let
    submitOne :: (DiffTime, SomeAction) -> m ()
    submitOne (delay, x) = withDelay delay $
      case x of
        SomeAction Generate.Base rb0 -> (GenRB,) $ do
          (rb, newChain) <- atomically $ do
            chain <- PraosNode.preferredChain st.praosState
            let rb = fixSize cfg.leios $ fixupBlock (Chain.headAnchor chain) rb0
            addProducedBlock st.praosState.blockFetchControllerState rb
            return (rb, chain :> rb)
          traceWith tracer (PraosNodeEvent (PraosNodeEventGenerate rb))
          traceWith tracer (PraosNodeEvent (PraosNodeEventNewTip newChain))
        SomeAction Generate.Propose{} ib -> (GenIB,) $ do
          atomically $ do
            -- TODO should not be added to 'relayIBState' before it's validated
            modifyTVar' st.relayIBState.relayBufferVar (RB.snocIfNew ib.header.id (ib.header, ib.body))
            adoptIB cfg.leios st ib IbDuringProposeOrDeliver1
          traceWith tracer (LeiosNodeEvent Generate (EventIB ib))
        SomeAction Generate.Endorse eb -> (GenEB,) $ do
          atomically $ do
            modifyTVar' st.relayEBState.relayBufferVar (RB.snocIfNew eb.id (RelayHeader eb.id eb.slot, eb))
            adoptEB st eb
          traceWith tracer (LeiosNodeEvent Generate (EventEB eb))
        SomeAction Generate.Vote v -> (GenVote,) $ do
          now <- getCurrentTime
          atomically $ do
            modifyTVar'
              st.relayVoteState.relayBufferVar
              (RB.snocIfNew v.id (RelayHeader v.id v.slot, v))
            adoptVote cfg.leios st v now
          traceWith tracer (LeiosNodeEvent Generate (EventVote v))
  let LeiosNodeConfig{..} = cfg
  leiosBlockGenerator $ LeiosGeneratorConfig{submit = mapM_ submitOne, ..}

mkBuffersView :: forall m. MonadSTM m => LeiosNodeConfig -> LeiosNodeState m -> BuffersView m
mkBuffersView cfg st = BuffersView{..}
 where
  newRBData = do
    -- This gets called pretty rarely, so doesn't seem worth caching,
    -- though it's getting more expensive as we go.
    chain <- PraosNode.preferredChain st.praosState
    bufferEB <- readTVar st.relayEBState.relayBufferVar
    votesForEB <- readTVar st.votesForEBVar
    -- RBs in the same chain should not contain certificates for the same pipeline.
    let pipelinesInChain =
          Set.fromList $
            [ endorseBlockPipeline cfg.leios eb
            | rb <- Chain.chainToList chain
            , (ebId, _) <- rb.blockBody.endorseBlocks
            , Just (_, eb) <- [RB.lookup bufferEB ebId]
            ]
    let tryCertify eb = do
          Certified{cert} <- Map.lookup eb.id votesForEB
          guard (not $ Set.member (endorseBlockPipeline cfg.leios eb) pipelinesInChain)
          return $! (eb.id,) $! cert

    -- TODO: cache index of EBs ordered by .slot?
    let orderEBs = case cfg.leios.variant of
          Short -> sortOn (\eb -> (eb.slot, Down $ length eb.inputBlocks))
          Full -> sortOn (\eb -> (Down eb.slot, Down $ length eb.inputBlocks))
    let certifiedEBforRBAt rbSlot =
          listToMaybe
            . mapMaybe tryCertify
            . orderEBs
            . filter (\eb -> not $ fromEnum eb.slot < fromEnum rbSlot - cfg.leios.maxEndorseBlockAgeSlots)
            . map snd
            . RB.values
            -- TODO: start from votesForEB, would allow to drop EBs from relayBuffer as soon as Endorse ends.
            $ bufferEB
    return $
      NewRankingBlockData
        { certifiedEBforRBAt
        , txsPayload = cfg.leios.sizes.rankingBlockLegacyPraosPayloadAvgSize
        }
  newIBData = do
    ledgerState <- readTVar st.ledgerStateVar
    referenceRankingBlock <-
      Chain.headHash . Chain.dropUntil (flip Map.member ledgerState . blockHash)
        <$> PraosNode.preferredChain st.praosState
    let txsPayload = cfg.leios.sizes.inputBlockBodyAvgSize
    return $ NewInputBlockData{referenceRankingBlock, txsPayload}
  ibs = do
    let splitLE k m =
          let (lt, mbEq, _gt) = Map.splitLookup k m
           in case mbEq of
                Nothing -> lt
                Just eq -> Map.insert k eq lt
        splitGE k m =
          let (_lt, mbEq, gt) = Map.splitLookup k m
           in case mbEq of
                Nothing -> gt
                Just eq -> Map.insert k eq gt
        generatedCheck (lo, hi) =
          Map.unions
            . splitGE lo
            . splitLE hi
        receivedByCheck hi =
          mapMaybe (\(ibId, deliveryStage) -> do guard (deliveryStage <= hi); Just ibId)
            . Map.toList
    xs <- readTVar st.iBsForEBsAndVotesVar
    let validInputBlocks q = receivedByCheck q.receivedBy . generatedCheck q.generatedBetween $ xs
    return InputBlocksSnapshot{..}
  ebs = do
    buffer <- readTVar st.relayEBState.relayBufferVar
    ebCerts <- readTVar st.votesForEBVar
    let validEndorseBlocks r =
          filter (\eb -> eb.slot `inRange` r) . map snd . RB.values $ buffer
        certifiedEndorseBlocks pr =
          Map.toAscList $
            Map.fromListWith (++) $
              [ (p, [(eb, c, t)])
              | eb <- map snd . RB.values $ buffer
              , let p = endorseBlockPipeline cfg.leios eb
              , p `inRange` pr
              , Just (Certified c t) <- [Map.lookup eb.id ebCerts]
              ]
    return EndorseBlocksSnapshot{..}

mkSchedule :: MonadSTM m => Tracer m LeiosNodeEvent -> LeiosNodeConfig -> m (SlotNo -> m [(SomeRole, Word64)])
mkSchedule tracer cfg = do
  -- For each pipeline, we want to deploy all our votes in a single
  -- message to cut down on traffic, so we pick one slot out of each
  -- active voting range (they are assumed not to overlap).
  votingSlots <- newTVarIO $ pickFromRanges rng1 $ votingRanges cfg.leios
  sched <- mkScheduler' rng2 (rates votingSlots)
  pure $! if cfg.conformanceEvents then logMissedBlocks sched else fmap filterWins . sched
 where
  (rng1, rng2) = split cfg.rng
  calcWins rate = Just $ \sample ->
    if sample <= coerce (nodeRate cfg.stake rate) then 1 else 0
  voteRate = votingRatePerPipeline cfg.leios cfg.stake
  honestIBRate = inputBlockRate cfg.leios cfg.stake
  ibRate Honest slot = (SomeRole (Generate.Propose Nothing Nothing), honestIBRate slot)
  ibRate (UnboundedIbs{..}) slot =
    if slot < startingAtSlot
      then (SomeRole (Generate.Propose Nothing Nothing), honestIBRate slot)
      else (SomeRole (Generate.Propose (Just slotOfGeneratedIbs) (Just 0)), Just (const $ ibsPerSlot))
  pureRates =
    [ (SomeRole Generate.Endorse, endorseBlockRate cfg.leios cfg.stake)
    , (SomeRole Generate.Base, const $ calcWins (NetworkRate cfg.leios.praos.blockFrequencyPerSlot))
    ]
  rates votingSlots slot = do
    when (cfg.conformanceEvents && (slot > 0)) $ traceWith tracer $ LeiosNodeEventConformance Slot{slot = slot - 1}
    vote <- atomically $ do
      vs <- readTVar votingSlots
      case vs of
        (sl : sls)
          | sl == slot -> do
              writeTVar votingSlots sls
              pure (Just voteRate)
        _ -> pure Nothing
    pure $
      [ (SomeRole Generate.Vote, vote)
      , ibRate cfg.blockGeneration slot
      ]
        ++ map (fmap ($ slot)) pureRates
  pickFromRanges :: StdGen -> [(SlotNo, SlotNo)] -> [SlotNo]
  pickFromRanges rng0 rs = snd $ mapAccumL f rng0 rs
   where
    f rng r = coerce $ swap $ uniformR (coerce r :: (Word64, Word64)) rng
  logMissedBlocks sched slot = do
    xs <- sched slot
    forM_ xs $ \(SomeRole role, wins) -> do
      when (wins == 0) $
        case role of
          Generate.Propose{} -> do
            traceWith tracer $ LeiosNodeEventConformance $ NoIBGenerated{..}
          Generate.Endorse{} -> do
            traceWith tracer $ LeiosNodeEventConformance $ NoEBGenerated{..}
          Generate.Vote{} -> do
            traceWith tracer $ LeiosNodeEventConformance $ NoVTGenerated{..}
          Generate.Base{} -> return ()
    return $ filterWins xs
  filterWins = filter ((>= 1) . snd)
-- * Utils

partitionRBVar ::
  (Ord key, MonadSTM m) =>
  TVar m (RB.RelayBuffer key value) ->
  (RB.EntryWithTicket key value -> Bool) ->
  STM m [value]
partitionRBVar var f = fmap RB.values . stateTVar' var $ RB.partition f

waitFor ::
  MonadSTM m =>
  TVar m (Map RankingBlockId [STM m ()]) ->
  [(RankingBlockId, [STM m ()])] ->
  STM m ()
waitFor var xs = do
  modifyTVar'
    var
    (flip (Map.unionWith (++)) $ Map.fromListWith (++) xs)
