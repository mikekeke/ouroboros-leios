use std::{
    collections::{hash_map::Entry, BTreeMap, BTreeSet, HashMap, HashSet},
    sync::Arc,
};

use anyhow::Result;
use netsim_async::HasBytesSize as _;
use priority_queue::PriorityQueue;
use rand::Rng as _;
use rand_chacha::ChaChaRng;
use tokio::{
    select,
    sync::{mpsc, watch},
};
use tracing::{info, trace};

use crate::{
    clock::{Clock, Timestamp},
    config::{NodeConfiguration, NodeId, SimConfiguration},
    events::EventTracker,
    model::{Block, InputBlock, InputBlockHeader, InputBlockId, Transaction, TransactionId},
    network::{NetworkSink, NetworkSource},
};

use super::SimulationMessage;

enum TransactionView {
    Pending,
    Received(Arc<Transaction>),
}

pub struct Node {
    pub id: NodeId,
    trace: bool,
    sim_config: Arc<SimConfiguration>,
    msg_source: NetworkSource<SimulationMessage>,
    msg_sink: NetworkSink<SimulationMessage>,
    slot_receiver: watch::Receiver<u64>,
    tx_source: mpsc::UnboundedReceiver<Arc<Transaction>>,
    tracker: EventTracker,
    rng: ChaChaRng,
    clock: Clock,
    stake: u64,
    total_stake: u64,
    peers: Vec<NodeId>,
    txs: HashMap<TransactionId, TransactionView>,
    praos: NodePraosState,
    leios: NodeLeiosState,
}

#[derive(Default)]
struct NodePraosState {
    mempool: BTreeMap<TransactionId, Arc<Transaction>>,
    peer_heads: BTreeMap<NodeId, u64>,
    blocks_seen: BTreeSet<u64>,
    blocks: BTreeMap<u64, Arc<Block>>,
}

#[derive(Default)]
struct NodeLeiosState {
    mempool: BTreeMap<TransactionId, Arc<Transaction>>,
    unsent_ibs: BTreeMap<u64, Vec<InputBlockHeader>>,
    ibs: BTreeMap<InputBlockId, Arc<InputBlock>>,
    pending_ibs: BTreeMap<InputBlockId, PendingInputBlock>,
    ib_requests: BTreeMap<NodeId, PeerInputBlockRequests>,
}

struct PendingInputBlock {
    header: InputBlockHeader,
    has_been_requested: bool,
}

#[derive(Default)]
struct PeerInputBlockRequests {
    pending: PriorityQueue<InputBlockId, Timestamp>,
    active: HashSet<InputBlockId>,
}

impl Node {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        config: &NodeConfiguration,
        sim_config: Arc<SimConfiguration>,
        total_stake: u64,
        msg_source: NetworkSource<SimulationMessage>,
        msg_sink: NetworkSink<SimulationMessage>,
        slot_receiver: watch::Receiver<u64>,
        tx_source: mpsc::UnboundedReceiver<Arc<Transaction>>,
        tracker: EventTracker,
        rng: ChaChaRng,
        clock: Clock,
    ) -> Self {
        let id = config.id;
        let stake = config.stake;
        let peers = config.peers.clone();
        Self {
            id,
            trace: sim_config.trace_nodes.contains(&id),
            sim_config,
            msg_source,
            msg_sink,
            slot_receiver,
            tx_source,
            tracker,
            rng,
            clock,
            stake,
            total_stake,
            peers,
            txs: HashMap::new(),
            praos: NodePraosState::default(),
            leios: NodeLeiosState::default(),
        }
    }

    pub async fn run(mut self) -> Result<()> {
        loop {
            select! {
                change_res = self.slot_receiver.changed() => {
                    if change_res.is_err() {
                        // sim has stopped running
                        break;
                    }
                    let slot = *self.slot_receiver.borrow();
                    self.handle_new_slot(slot)?;
                }
                maybe_tx = self.tx_source.recv() => {
                    let Some(tx) = maybe_tx else {
                        // sim has stopped running
                        break;
                    };
                    self.receive_tx(self.id, tx)?;
                }
                maybe_msg = self.msg_source.recv() => {
                    let Some((from, msg)) = maybe_msg else {
                        // sim has stopped running
                        break;
                    };
                    match msg {
                        // TX propagation
                        SimulationMessage::AnnounceTx(id) => {
                            self.receive_announce_tx(from, id)?;
                        }
                        SimulationMessage::RequestTx(id) => {
                            self.receive_request_tx(from, id)?;
                        }
                        SimulationMessage::Tx(tx) => {
                            self.receive_tx(from, tx)?;
                        }

                        // Block propagation
                        SimulationMessage::RollForward(slot) => {
                            self.receive_roll_forward(from, slot)?;
                        }
                        SimulationMessage::RequestBlock(slot) => {
                            self.receive_request_block(from, slot)?;
                        }
                        SimulationMessage::Block(block) => {
                            self.receive_block(from, block)?;
                        }

                        // IB header propagation
                        SimulationMessage::AnnounceIBHeader(id) => {
                            self.receive_announce_ib_header(from, id)?;
                        }
                        SimulationMessage::RequestIBHeader(id) => {
                            self.receive_request_ib_header(from, id)?;
                        }
                        SimulationMessage::IBHeader(header, has_body) => {
                            self.receive_ib_header(from, header, has_body)?;
                        }

                        // IB transmission
                        SimulationMessage::AnnounceIB(id) => {
                            self.receive_announce_ib(from, id)?;
                        }
                        SimulationMessage::RequestIB(id) => {
                            self.receive_request_ib(from, id)?;
                        }
                        SimulationMessage::IB(ib) => {
                            self.receive_ib(from, ib)?;
                        }
                    }
                }
            };
        }
        Ok(())
    }

    fn handle_new_slot(&mut self, slot: u64) -> Result<()> {
        // The beginning of a new slot is the end of an old slot.
        // Publish any input blocks left over from the last slot

        if slot % self.sim_config.stage_length == 0 {
            // A new stage has begun. Decide how many IBs to generate in each slot.
            self.schedule_input_block_generation(slot);
        }

        // Generate any IBs scheduled for this slot.
        self.generate_input_blocks(slot)?;

        self.try_generate_praos_block(slot)?;

        Ok(())
    }

    fn schedule_input_block_generation(&mut self, slot: u64) {
        let mut probability = self.sim_config.ib_generation_probability;
        let mut slot_vrfs: BTreeMap<u64, Vec<u64>> = BTreeMap::new();
        while probability > 0.0 {
            let next_p = f64::min(probability, 1.0);
            if let Some(vrf) = self.run_vrf(next_p) {
                let vrf_slot = if self.sim_config.uniform_ib_generation {
                    // IBs are generated at the start of any slot within this stage
                    slot + self.rng.gen_range(0..self.sim_config.stage_length)
                } else {
                    // IBs are generated at the start of the first slot of this stage
                    slot
                };
                slot_vrfs.entry(vrf_slot).or_default().push(vrf);
            }
            probability -= 1.0;
        }
        for (slot, vrfs) in slot_vrfs {
            let headers = vrfs
                .into_iter()
                .enumerate()
                .map(|(index, vrf)| InputBlockHeader {
                    slot,
                    producer: self.id,
                    index: index as u64,
                    vrf,
                    timestamp: self.clock.now(),
                })
                .collect();
            self.leios.unsent_ibs.insert(slot, headers);
        }
    }

    fn generate_input_blocks(&mut self, slot: u64) -> Result<()> {
        let Some(headers) = self.leios.unsent_ibs.remove(&slot) else {
            return Ok(());
        };
        for header in headers {
            let mut ib = InputBlock {
                header,
                transactions: vec![],
            };
            self.try_filling_ib(&mut ib);
            if !ib.transactions.is_empty() {
                self.generate_ib(ib)?;
            } else {
                self.tracker.track_empty_ib_not_generated(&ib.header);
            }
        }
        Ok(())
    }

    fn try_generate_praos_block(&mut self, slot: u64) -> Result<()> {
        // L1 block generation
        let Some(vrf) = self.run_vrf(self.sim_config.block_generation_probability) else {
            return Ok(());
        };

        // Fill a block with as many pending transactions as can fit
        let mut size = 0;
        let mut transactions = vec![];
        while let Some((id, tx)) = self.praos.mempool.first_key_value() {
            if size + tx.bytes > self.sim_config.max_block_size {
                break;
            }
            size += tx.bytes;
            let id = *id;
            transactions.push(self.praos.mempool.remove(&id).unwrap());
        }

        let block = Block {
            slot,
            producer: self.id,
            vrf,
            transactions,
        };
        self.tracker.track_praos_block_generated(&block);
        self.publish_block(Arc::new(block))?;

        Ok(())
    }

    fn publish_block(&mut self, block: Arc<Block>) -> Result<()> {
        // Do not remove TXs in these blocks from the leios mempool.
        // Wait until we learn more about how praos and leios interact.
        for peer in &self.peers {
            if !self
                .praos
                .peer_heads
                .get(peer)
                .is_some_and(|&s| s >= block.slot)
            {
                self.send_to(*peer, SimulationMessage::RollForward(block.slot))?;
                self.praos.peer_heads.insert(*peer, block.slot);
            }
        }
        self.praos.blocks.insert(block.slot, block);
        Ok(())
    }

    fn receive_announce_tx(&mut self, from: NodeId, id: TransactionId) -> Result<()> {
        if let Entry::Vacant(e) = self.txs.entry(id) {
            e.insert(TransactionView::Pending);
            self.send_to(from, SimulationMessage::RequestTx(id))?;
        }
        Ok(())
    }

    fn receive_request_tx(&mut self, from: NodeId, id: TransactionId) -> Result<()> {
        if let Some(TransactionView::Received(tx)) = self.txs.get(&id) {
            self.tracker.track_transaction_sent(tx.id, self.id, from);
            self.send_to(from, SimulationMessage::Tx(tx.clone()))?;
        }
        Ok(())
    }

    fn receive_tx(&mut self, from: NodeId, tx: Arc<Transaction>) -> Result<()> {
        let id = tx.id;
        if from != self.id {
            self.tracker
                .track_transaction_received(tx.id, from, self.id);
        }
        if self.trace {
            info!("node {} saw tx {id}", self.id);
        }
        self.txs.insert(id, TransactionView::Received(tx.clone()));
        self.praos.mempool.insert(tx.id, tx.clone());
        for peer in &self.peers {
            if *peer == from {
                continue;
            }
            self.send_to(*peer, SimulationMessage::AnnounceTx(id))?;
        }
        self.leios.mempool.insert(tx.id, tx);
        Ok(())
    }

    fn receive_roll_forward(&mut self, from: NodeId, slot: u64) -> Result<()> {
        if self.praos.blocks_seen.insert(slot) {
            self.send_to(from, SimulationMessage::RequestBlock(slot))?;
        }
        Ok(())
    }

    fn receive_request_block(&mut self, from: NodeId, slot: u64) -> Result<()> {
        if let Some(block) = self.praos.blocks.get(&slot) {
            self.tracker.track_praos_block_sent(block, self.id, from);
            self.send_to(from, SimulationMessage::Block(block.clone()))?;
        }
        Ok(())
    }

    fn receive_block(&mut self, from: NodeId, block: Arc<Block>) -> Result<()> {
        self.tracker
            .track_praos_block_received(&block, from, self.id);
        if self
            .praos
            .blocks
            .insert(block.slot, block.clone())
            .is_none()
        {
            // Do not remove TXs in these blocks from the leios mempool.
            // Wait until we learn more about how praos and leios interact.
            let head = self.praos.peer_heads.entry(from).or_default();
            if *head < block.slot {
                *head = block.slot
            }
            self.publish_block(block)?;
        }
        Ok(())
    }

    fn receive_announce_ib_header(&mut self, from: NodeId, id: InputBlockId) -> Result<()> {
        self.send_to(from, SimulationMessage::RequestIBHeader(id))?;
        Ok(())
    }

    fn receive_request_ib_header(&mut self, from: NodeId, id: InputBlockId) -> Result<()> {
        if let Some(pending_ib) = self.leios.pending_ibs.get(&id) {
            // We don't have this IB, just the header. Send that.
            self.send_to(
                from,
                SimulationMessage::IBHeader(pending_ib.header.clone(), false),
            )?;
        } else if let Some(ib) = self.leios.ibs.get(&id) {
            // We have the full IB. Send the header, and also advertise that we have the full IB.
            self.send_to(from, SimulationMessage::IBHeader(ib.header.clone(), true))?;
        }
        Ok(())
    }

    fn receive_ib_header(
        &mut self,
        from: NodeId,
        header: InputBlockHeader,
        has_body: bool,
    ) -> Result<()> {
        let id = header.id();
        if self.leios.ibs.contains_key(&id) {
            return Ok(());
        }
        if self.leios.pending_ibs.contains_key(&id) {
            return Ok(());
        }
        self.leios.pending_ibs.insert(
            id,
            PendingInputBlock {
                header,
                has_been_requested: false,
            },
        );
        // We haven't seen this header before, so propagate it to our neighbors
        for peer in &self.peers {
            if *peer == from {
                continue;
            }
            self.send_to(*peer, SimulationMessage::AnnounceIBHeader(id))?;
        }
        if has_body {
            // Whoever sent us this IB header has also announced that they have the body.
            // If we still need it, download it from them.
            self.receive_announce_ib(from, id)?;
        }
        Ok(())
    }

    fn receive_announce_ib(&mut self, from: NodeId, id: InputBlockId) -> Result<()> {
        let Some(pending_ib) = self.leios.pending_ibs.get_mut(&id) else {
            return Ok(());
        };
        // Ignore IBs which have already been requested
        if pending_ib.has_been_requested {
            return Ok(());
        }
        // Do we have capacity to request this block?
        let reqs = self.leios.ib_requests.entry(from).or_default();
        if reqs.active.len() < self.sim_config.max_ib_requests_per_peer {
            // If so, make the request
            pending_ib.has_been_requested = true;
            reqs.active.insert(id);
            self.send_to(from, SimulationMessage::RequestIB(id))?;
        } else {
            // If not, just track that this peer has this IB when we're ready
            reqs.pending.push(id, pending_ib.header.timestamp);
        }
        Ok(())
    }

    fn receive_request_ib(&mut self, from: NodeId, id: InputBlockId) -> Result<()> {
        if let Some(ib) = self.leios.ibs.get(&id) {
            self.tracker.track_ib_sent(id, self.id, from);
            self.send_to(from, SimulationMessage::IB(ib.clone()))?;
        }
        Ok(())
    }

    fn receive_ib(&mut self, from: NodeId, ib: Arc<InputBlock>) -> Result<()> {
        let id = ib.header.id();
        self.tracker.track_ib_received(id, from, self.id);
        for transaction in &ib.transactions {
            // Do not include transactions from this IB in any IBs we produce ourselves.
            self.leios.mempool.remove(&transaction.id);
        }
        self.leios.ibs.insert(id, ib);

        for peer in &self.peers {
            if *peer == from {
                continue;
            }
            self.send_to(*peer, SimulationMessage::AnnounceIB(id))?;
        }

        // Mark that this IB is no longer pending
        self.leios.pending_ibs.remove(&id);
        let reqs = self.leios.ib_requests.entry(from).or_default();
        reqs.active.remove(&id);

        // We now have capacity to request one more IB from this peer
        while let Some((id, _)) = reqs.pending.pop() {
            let Some(pending_ib) = self.leios.pending_ibs.get_mut(&id) else {
                // We fetched this IB from some other node already
                continue;
            };
            if pending_ib.has_been_requested {
                // There's already a request for this IB in flight
                continue;
            }

            // Make the request
            pending_ib.has_been_requested = true;
            reqs.active.insert(id);
            self.send_to(from, SimulationMessage::RequestIB(id))?;
            break;
        }

        Ok(())
    }

    fn try_filling_ib(&mut self, ib: &mut InputBlock) {
        let shard = ib.header.vrf % self.sim_config.ib_shards;
        let candidate_txs: Vec<_> = self
            .leios
            .mempool
            .values()
            .filter_map(|tx| {
                if tx.shard == shard {
                    Some((tx.id, tx.bytes))
                } else {
                    None
                }
            })
            .collect();
        for (id, bytes) in candidate_txs {
            let remaining_capacity = self.sim_config.max_ib_size - ib.bytes();
            if remaining_capacity < bytes {
                continue;
            }
            ib.transactions
                .push(self.leios.mempool.remove(&id).unwrap());
        }
    }

    fn generate_ib(&mut self, mut ib: InputBlock) -> Result<()> {
        ib.header.timestamp = self.clock.now();
        let ib = Arc::new(ib);

        self.tracker.track_ib_generated(&ib);

        let id = ib.header.id();
        self.leios.ibs.insert(id, ib);
        for peer in &self.peers {
            self.send_to(*peer, SimulationMessage::AnnounceIBHeader(id))?;
        }
        Ok(())
    }

    // Simulates the output of a VRF using this node's stake (if any).
    fn run_vrf(&mut self, success_rate: f64) -> Option<u64> {
        let target_vrf_stake = compute_target_vrf_stake(self.stake, self.total_stake, success_rate);
        let result = self.rng.gen_range(0..self.total_stake);
        if result < target_vrf_stake {
            Some(result)
        } else {
            None
        }
    }

    fn send_to(&self, to: NodeId, msg: SimulationMessage) -> Result<()> {
        if self.trace {
            trace!(
                "node {} sent msg of size {} to node {to}",
                self.id,
                msg.bytes_size()
            );
        }
        self.msg_sink.send_to(to, msg)
    }
}

fn compute_target_vrf_stake(stake: u64, total_stake: u64, success_rate: f64) -> u64 {
    let ratio = stake as f64 / total_stake as f64;
    (total_stake as f64 * ratio * success_rate) as u64
}
