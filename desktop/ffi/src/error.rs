use gossip_core::engine::{DialError, SendError};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum GossipError {
    #[error("invalid argument: {reason}")]
    InvalidArgument { reason: String },
    #[error("not connected to any peer that can receive this")]
    NotConnected,
    #[error("message too large")]
    TooLarge,
    #[error("the payload cannot be signed: {reason}")]
    Unsignable { reason: String },
    #[error("encryption failed")]
    Encryption,
    #[error("cannot dial: {reason}")]
    Dial { reason: String },
}

impl GossipError {
    pub(crate) fn invalid(reason: impl Into<String>) -> Self {
        Self::InvalidArgument {
            reason: reason.into(),
        }
    }
}

impl From<SendError> for GossipError {
    fn from(e: SendError) -> Self {
        match e {
            SendError::NotConnected => Self::NotConnected,
            SendError::TooLarge => Self::TooLarge,
            SendError::Unsignable(reason) => Self::Unsignable { reason },
            SendError::Encryption => Self::Encryption,
        }
    }
}

impl From<DialError> for GossipError {
    fn from(e: DialError) -> Self {
        Self::Dial {
            reason: e.to_string(),
        }
    }
}
