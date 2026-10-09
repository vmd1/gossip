//! Reconciliation scheduling: the repo-wide rule that anything configuring persistent state on a peer is resent on
//! every fresh connect and again on a timer, so a send lost to a disconnect race heals itself. Every receiver is
//! idempotent, which is what makes firing these repeatedly whether or not anything changed safe.
//!
//! The core owns *when*; the feature owns *what* to send. The engine emits [`Due`] values and the shell (or the
//! feature logic) answers each with the right message.

use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Task {
    /// The message type this task resends.
    pub name: &'static str,
    pub interval_ms: i64,
}

/// Every message type that configures persistent state on its recipient.
pub const TASKS: &[Task] = &[
    Task {
        name: "trust.roster_update",
        interval_ms: 300_000,
    },
    Task {
        name: "ble.beacon_key",
        interval_ms: 300_000,
    },
    Task {
        name: "dnd.update",
        interval_ms: 60_000,
    },
    Task {
        name: "lock_on_leave.config",
        interval_ms: 60_000,
    },
    Task {
        name: "battery.update",
        interval_ms: 60_000,
    },
    Task {
        name: "hotspot.state_update",
        interval_ms: 60_000,
    },
    Task {
        name: "display.info",
        interval_ms: 60_000,
    },
    Task {
        name: "clipboard.update",
        interval_ms: 60_000,
    },
];

/// A reconciliation send that is due.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Due {
    pub task: &'static str,
    /// `Some(peer)` for the on-connect send to one newly connected peer, `None` for the periodic broadcast resync.
    pub peer: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Reconciler {
    tasks: Vec<Task>,
    last_run: HashMap<&'static str, i64>,
}

impl Default for Reconciler {
    fn default() -> Self {
        Self::new(TASKS.to_vec())
    }
}

impl Reconciler {
    pub fn new(tasks: Vec<Task>) -> Self {
        Self {
            tasks,
            last_run: HashMap::new(),
        }
    }

    /// A trusted peer just became live: every task is due for it, immediately.
    pub fn on_peer_connected(&self, peer: &str) -> Vec<Due> {
        self.tasks
            .iter()
            .map(|t| Due {
                task: t.name,
                peer: Some(peer.to_owned()),
            })
            .collect()
    }

    /// Call periodically (a one-second timer is plenty). Returns the tasks whose interval has elapsed. Nothing is
    /// due while no peer is connected, and a task's clock restarts when it fires.
    pub fn tick(&mut self, now_ms: i64, any_peer_connected: bool) -> Vec<Due> {
        if !any_peer_connected {
            // Start the clocks fresh at the next connect rather than firing a backlog.
            self.last_run.clear();
            return Vec::new();
        }
        let mut due = Vec::new();
        for task in &self.tasks {
            let last = *self.last_run.entry(task.name).or_insert(now_ms);
            if now_ms - last >= task.interval_ms {
                self.last_run.insert(task.name, now_ms);
                due.push(Due {
                    task: task.name,
                    peer: None,
                });
            }
        }
        due
    }
}
