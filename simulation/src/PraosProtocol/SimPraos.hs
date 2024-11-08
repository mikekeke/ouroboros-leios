{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module PraosProtocol.SimPraos where

import ChanMux
import ChanTCP
import Control.Monad.Class.MonadAsync (
  MonadAsync (concurrently_),
 )
import Control.Monad.IOSim as IOSim (IOSim, runSimTrace)
import Control.Tracer as Tracer (
  Contravariant (contramap),
  Tracer,
  traceWith,
 )
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import PraosProtocol.Common hiding (Point)
import PraosProtocol.Common.Chain (Chain (..))
import PraosProtocol.PraosNode (PraosMessage, runPraosNode)
import SimTCPLinks
import SimTypes

type PraosTrace = [(Time, PraosEvent)]

data PraosEvent
  = -- | Declare the nodes and links
    PraosEventSetup
      !WorldShape
      !(Map NodeId Point) -- nodes and locations
      !(Set (NodeId, NodeId)) -- links between nodes
  | -- | An event at a node
    PraosEventNode (LabelNode PraosNodeEvent)
  | -- | An event on a tcp link between two nodes
    PraosEventTcp (LabelLink (TcpEvent PraosMessage))
  deriving (Show)

exampleTrace1 :: PraosTrace
exampleTrace1 = traceRelayLink1 $ mkTcpConnProps 0.1 1000000

traceRelayLink1 ::
  TcpConnProps ->
  PraosTrace
traceRelayLink1 tcpprops =
  selectTimedEvents $
    runSimTrace $ do
      traceWith tracer $
        PraosEventSetup
          WorldShape
            { worldDimensions = (500, 500)
            , worldIsCylinder = False
            }
          ( Map.fromList
              [ (nodeA, Point 50 100)
              , (nodeB, Point 450 100)
              ]
          )
          ( Set.fromList
              [(nodeA, nodeB), (nodeB, nodeA)]
          )
      slotConfig <- slotConfigFromNow
      let praosConfig = PraosConfig{slotConfig, blockValidationDelay = const 0.1}
      let chainA = mkChainSimple $ [BlockBody (BS.singleton word) | word <- [0 .. 9]]
      let chainB = Genesis
      (pA, cB) <- newConnectionBundleTCP (praosTracer nodeA nodeB) tcpprops
      (cA, pB) <- newConnectionBundleTCP (praosTracer nodeA nodeB) tcpprops
      concurrently_
        (runPraosNode (nodeTracer nodeA) praosConfig chainA [pA] [cA])
        (runPraosNode (nodeTracer nodeB) praosConfig chainB [pB] [cB])
      return ()
 where
  (nodeA, nodeB) = (NodeId 0, NodeId 1)

  tracer :: Tracer (IOSim s) PraosEvent
  tracer = simTracer

  nodeTracer :: NodeId -> Tracer (IOSim s) PraosNodeEvent
  nodeTracer n =
    contramap (PraosEventNode . LabelNode n) tracer

  praosTracer ::
    NodeId ->
    NodeId ->
    Tracer (IOSim s) (LabelTcpDir (TcpEvent PraosMessage))
  praosTracer nfrom nto =
    contramap (PraosEventTcp . labelDirToLabelLink nfrom nto) tracer
