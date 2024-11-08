use serde::Serialize;
use tokio::sync::mpsc;
use tracing::warn;

use crate::{
    clock::{Clock, Timestamp},
    config::NodeId,
    model::{Block, InputBlock, InputBlockHeader, InputBlockId, Transaction, TransactionId},
};

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
pub enum Event {
    Slot {
        number: u64,
    },
    TransactionGenerated {
        id: TransactionId,
        publisher: NodeId,
        bytes: u64,
    },
    TransactionSent {
        id: TransactionId,
        sender: NodeId,
        recipient: NodeId,
    },
    TransactionReceived {
        id: TransactionId,
        sender: NodeId,
        recipient: NodeId,
    },
    PraosBlockGenerated {
        slot: u64,
        producer: NodeId,
        vrf: u64,
        transactions: Vec<TransactionId>,
    },
    PraosBlockSent {
        slot: u64,
        sender: NodeId,
        recipient: NodeId,
    },
    PraosBlockReceived {
        slot: u64,
        sender: NodeId,
        recipient: NodeId,
    },
    InputBlockGenerated {
        #[serde(flatten)]
        header: InputBlockHeader,
        transactions: Vec<TransactionId>,
    },
    EmptyInputBlockNotGenerated {
        #[serde(flatten)]
        header: InputBlockHeader,
    },
    InputBlockSent {
        #[serde(flatten)]
        id: InputBlockId,
        sender: NodeId,
        recipient: NodeId,
    },
    InputBlockReceived {
        #[serde(flatten)]
        id: InputBlockId,
        sender: NodeId,
        recipient: NodeId,
    },
}

#[derive(Clone)]
pub struct EventTracker {
    sender: mpsc::UnboundedSender<(Event, Timestamp)>,
    clock: Clock,
}

impl EventTracker {
    pub fn new(sender: mpsc::UnboundedSender<(Event, Timestamp)>, clock: Clock) -> Self {
        Self { sender, clock }
    }

    pub fn track_slot(&self, number: u64) {
        self.send(Event::Slot { number });
    }

    pub fn track_praos_block_generated(&self, block: &Block) {
        self.send(Event::PraosBlockGenerated {
            slot: block.slot,
            producer: block.producer,
            vrf: block.vrf,
            transactions: block.transactions.iter().map(|tx| tx.id).collect(),
        });
    }

    pub fn track_praos_block_sent(&self, block: &Block, sender: NodeId, recipient: NodeId) {
        self.send(Event::PraosBlockSent {
            slot: block.slot,
            sender,
            recipient,
        });
    }

    pub fn track_praos_block_received(&self, block: &Block, sender: NodeId, recipient: NodeId) {
        self.send(Event::PraosBlockReceived {
            slot: block.slot,
            sender,
            recipient,
        });
    }

    pub fn track_transaction_generated(&self, transaction: &Transaction, publisher: NodeId) {
        self.send(Event::TransactionGenerated {
            id: transaction.id,
            publisher,
            bytes: transaction.bytes,
        });
    }

    pub fn track_transaction_sent(&self, id: TransactionId, sender: NodeId, recipient: NodeId) {
        self.send(Event::TransactionSent {
            id,
            sender,
            recipient,
        });
    }

    pub fn track_transaction_received(&self, id: TransactionId, sender: NodeId, recipient: NodeId) {
        self.send(Event::TransactionReceived {
            id,
            sender,
            recipient,
        });
    }

    pub fn track_ib_generated(&self, block: &InputBlock) {
        self.send(Event::InputBlockGenerated {
            header: block.header.clone(),
            transactions: block.transactions.iter().map(|tx| tx.id).collect(),
        });
    }

    pub fn track_empty_ib_not_generated(&self, header: &InputBlockHeader) {
        self.send(Event::EmptyInputBlockNotGenerated {
            header: header.clone(),
        });
    }

    pub fn track_ib_sent(&self, id: InputBlockId, sender: NodeId, recipient: NodeId) {
        self.send(Event::InputBlockSent {
            id,
            sender,
            recipient,
        });
    }

    pub fn track_ib_received(&self, id: InputBlockId, sender: NodeId, recipient: NodeId) {
        self.send(Event::InputBlockReceived {
            id,
            sender,
            recipient,
        });
    }

    fn send(&self, event: Event) {
        if self.sender.send((event, self.clock.now())).is_err() {
            warn!("tried sending event after aggregator finished");
        }
    }
}
