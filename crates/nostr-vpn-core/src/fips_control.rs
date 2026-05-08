use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::join_requests::MeshJoinRequest;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkRoster {
    #[serde(default)]
    pub network_name: String,
    pub participants: Vec<String>,
    #[serde(default)]
    pub admins: Vec<String>,
    #[serde(default)]
    pub aliases: HashMap<String, String>,
    #[serde(default)]
    pub signed_at: u64,
}

const FIPS_CONTROL_MAGIC: &[u8] = b"NVPN-FIPS-CTRL\0";
const FIPS_CONTROL_VERSION: u8 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FipsControlFrame {
    Ping {
        network_id: String,
        sent_at: u64,
    },
    Pong {
        network_id: String,
        sent_at: u64,
        replied_at: u64,
    },
    JoinRequest {
        requested_at: u64,
        request: MeshJoinRequest,
    },
    Roster {
        network_id: String,
        roster: NetworkRoster,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct FipsControlEnvelope {
    v: u8,
    frame: FipsControlFrame,
}

pub fn encode_fips_control_frame(frame: &FipsControlFrame) -> Result<Vec<u8>> {
    let envelope = FipsControlEnvelope {
        v: FIPS_CONTROL_VERSION,
        frame: frame.clone(),
    };
    let mut out = Vec::from(FIPS_CONTROL_MAGIC);
    out.extend_from_slice(
        &serde_json::to_vec(&envelope).context("failed to encode FIPS control frame")?,
    );
    Ok(out)
}

pub fn decode_fips_control_frame(data: &[u8]) -> Result<Option<FipsControlFrame>> {
    let Some(payload) = data.strip_prefix(FIPS_CONTROL_MAGIC) else {
        return Ok(None);
    };
    let envelope: FipsControlEnvelope =
        serde_json::from_slice(payload).context("failed to decode FIPS control frame")?;
    if envelope.v != FIPS_CONTROL_VERSION {
        return Err(anyhow!(
            "unsupported FIPS control frame version {}; expected {}",
            envelope.v,
            FIPS_CONTROL_VERSION
        ));
    }
    Ok(Some(envelope.frame))
}

pub fn roster_control_frame(
    network_id: impl Into<String>,
    roster: NetworkRoster,
) -> FipsControlFrame {
    FipsControlFrame::Roster {
        network_id: network_id.into(),
        roster,
    }
}

pub fn network_roster_from_shared(
    network_name: String,
    participants: Vec<String>,
    admins: Vec<String>,
    aliases: HashMap<String, String>,
    signed_at: u64,
) -> NetworkRoster {
    NetworkRoster {
        network_name,
        participants,
        admins,
        aliases,
        signed_at,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_frame_roundtrips_with_magic_prefix() {
        let frame = FipsControlFrame::Ping {
            network_id: "mesh".to_string(),
            sent_at: 42,
        };

        let encoded = encode_fips_control_frame(&frame).expect("encode");
        assert!(encoded.starts_with(FIPS_CONTROL_MAGIC));

        let decoded = decode_fips_control_frame(&encoded)
            .expect("decode")
            .expect("control frame");
        assert_eq!(decoded, frame);
    }

    #[test]
    fn raw_packet_is_not_control() {
        let packet = [0x45, 0, 0, 20];

        assert!(
            decode_fips_control_frame(&packet)
                .expect("decode")
                .is_none()
        );
    }
}
