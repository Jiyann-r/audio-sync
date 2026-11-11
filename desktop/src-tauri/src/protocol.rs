use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Exact size in bytes of the custom UDP framing header:
/// `[PacketType (1B) | StreamID (1B) | SequenceNum (2B) | Timestamp (4B)]`
pub const HEADER_SIZE: usize = 8;

/// Maximum safe UDP datagram payload size (standard MTU 1500 - IP 20B - UDP 8B).
pub const MAX_UDP_DATAGRAM_SIZE: usize = 1472;

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("UDP packet too short: expected at least {HEADER_SIZE} bytes, got {0}")]
    PacketTooShort(usize),
    #[error("Unknown PacketType byte: 0x{0:02x}")]
    UnknownPacketType(u8),
    #[error("Unknown StreamID byte: 0x{0:02x}")]
    UnknownStreamId(u8),
    #[error("Destination buffer too small: needed {needed} bytes, available {available}")]
    BufferTooSmall { needed: usize, available: usize },
    #[error("Control payload serialization error: {0}")]
    ControlPayloadError(String),
}

/// 1-Byte PacketType field (offset 0).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PacketType {
    /// Opus-encoded audio frame payload.
    AudioOpus = 0x01,
    /// Latency measurement request (echoed back via `Pong`).
    Ping = 0x02,
    /// Latency measurement response echoing sender's `SequenceNum` & `Timestamp`.
    Pong = 0x03,
    /// Control signaling message (JSON-encoded `ControlMessage`).
    Control = 0x04,
}

impl TryFrom<u8> for PacketType {
    type Error = ProtocolError;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0x01 => Ok(PacketType::AudioOpus),
            0x02 => Ok(PacketType::Ping),
            0x03 => Ok(PacketType::Pong),
            0x04 => Ok(PacketType::Control),
            other => Err(ProtocolError::UnknownPacketType(other)),
        }
    }
}

/// 1-Byte StreamID field (offset 1).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum StreamId {
    /// Control / Ping-Pong / Signaling stream.
    Control = 0x00,
    /// PC Desktop WASAPI Loopback -> iPhone Speaker/Headphones (48kHz Stereo Opus).
    PcToPhone = 0x01,
    /// iPhone Microphone -> PC VB-CABLE Virtual Microphone (48kHz Mono/Stereo Opus).
    PhoneToPc = 0x02,
}

impl TryFrom<u8> for StreamId {
    type Error = ProtocolError;

    #[inline]
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0x00 => Ok(StreamId::Control),
            0x01 => Ok(StreamId::PcToPhone),
            0x02 => Ok(StreamId::PhoneToPc),
            other => Err(ProtocolError::UnknownStreamId(other)),
        }
    }
}

/// 8-byte wire header:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |  PacketType   |   StreamID    |          SequenceNum          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Timestamp                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PacketHeader {
    pub packet_type: PacketType,
    pub stream_id: StreamId,
    pub sequence_num: u16,
    pub timestamp: u32,
}

impl PacketHeader {
    #[inline]
    pub const fn new(
        packet_type: PacketType,
        stream_id: StreamId,
        sequence_num: u16,
        timestamp: u32,
    ) -> Self {
        Self {
            packet_type,
            stream_id,
            sequence_num,
            timestamp,
        }
    }

    /// Serializes the header into an 8-byte network-order (big-endian) array.
    #[inline]
    pub const fn to_bytes(&self) -> [u8; HEADER_SIZE] {
        let seq = self.sequence_num.to_be_bytes();
        let ts = self.timestamp.to_be_bytes();
        [
            self.packet_type as u8,
            self.stream_id as u8,
            seq[0],
            seq[1],
            ts[0],
            ts[1],
            ts[2],
            ts[3],
        ]
    }

    /// Parses an 8-byte network-order (big-endian) slice into a `PacketHeader`.
    #[inline]
    pub fn from_bytes(buf: &[u8]) -> Result<Self, ProtocolError> {
        if buf.len() < HEADER_SIZE {
            return Err(ProtocolError::PacketTooShort(buf.len()));
        }
        let packet_type = PacketType::try_from(buf[0])?;
        let stream_id = StreamId::try_from(buf[1])?;
        let sequence_num = u16::from_be_bytes([buf[2], buf[3]]);
        let timestamp = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);

        Ok(Self {
            packet_type,
            stream_id,
            sequence_num,
            timestamp,
        })
    }
}

/// Complete framed UDP packet consisting of the 8-byte `PacketHeader` and variable payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FramedPacket {
    pub header: PacketHeader,
    pub payload: Vec<u8>,
}

impl FramedPacket {
    pub fn new(
        packet_type: PacketType,
        stream_id: StreamId,
        sequence_num: u16,
        timestamp: u32,
        payload: Vec<u8>,
    ) -> Self {
        Self {
            header: PacketHeader::new(packet_type, stream_id, sequence_num, timestamp),
            payload,
        }
    }

    pub fn ping(sequence_num: u16, timestamp: u32) -> Self {
        Self::new(
            PacketType::Ping,
            StreamId::Control,
            sequence_num,
            timestamp,
            Vec::new(),
        )
    }

    pub fn pong(sequence_num: u16, timestamp: u32) -> Self {
        Self::new(
            PacketType::Pong,
            StreamId::Control,
            sequence_num,
            timestamp,
            Vec::new(),
        )
    }

    pub fn control(
        sequence_num: u16,
        timestamp: u32,
        msg: &ControlMessage,
    ) -> Result<Self, ProtocolError> {
        let payload = serde_json::to_vec(msg)
            .map_err(|e| ProtocolError::ControlPayloadError(e.to_string()))?;
        Ok(Self::new(
            PacketType::Control,
            StreamId::Control,
            sequence_num,
            timestamp,
            payload,
        ))
    }

    /// Encodes the packet header + payload into a newly allocated byte vector.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_SIZE + self.payload.len());
        out.extend_from_slice(&self.header.to_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    /// Zero-allocation encoding into a pre-allocated mutable buffer.
    pub fn encode_into(&self, dst: &mut [u8]) -> Result<usize, ProtocolError> {
        let total_len = HEADER_SIZE + self.payload.len();
        if dst.len() < total_len {
            return Err(ProtocolError::BufferTooSmall {
                needed: total_len,
                available: dst.len(),
            });
        }
        dst[..HEADER_SIZE].copy_from_slice(&self.header.to_bytes());
        dst[HEADER_SIZE..total_len].copy_from_slice(&self.payload);
        Ok(total_len)
    }

    /// Decodes a raw UDP datagram into a `FramedPacket`.
    pub fn decode(datagram: &[u8]) -> Result<Self, ProtocolError> {
        let header = PacketHeader::from_bytes(datagram)?;
        let payload = datagram[HEADER_SIZE..].to_vec();
        Ok(Self { header, payload })
    }
}

/// Control messages transmitted inside `PacketType::Control` payloads.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ControlMessage {
    Handshake {
        device_name: String,
        protocol_version: u8,
        sample_rate: u32,
        channels: u8,
    },
    HandshakeAck {
        server_name: String,
        pc_to_phone_enabled: bool,
        phone_to_pc_enabled: bool,
        opus_bitrate: i32,
    },
    MuteState {
        stream_id: StreamId,
        muted: bool,
    },
    StreamConfig {
        opus_bitrate: i32,
        frame_duration_ms: u8,
        jitter_capacity: usize,
        noise_suppression_enabled: bool,
        gain_db: f32,
    },
    Disconnect {
        reason: String,
    },
}

/// Returns the difference `a - b` in 16-bit wrapping sequence number space.
#[inline]
pub const fn sequence_diff(a: u16, b: u16) -> i16 {
    a.wrapping_sub(b) as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_packet_header_roundtrip() {
        let header = PacketHeader::new(
            PacketType::AudioOpus,
            StreamId::PcToPhone,
            0x1234,
            0xAABBCCDD,
        );
        let bytes = header.to_bytes();
        assert_eq!(bytes.len(), 8);
        assert_eq!(bytes, [0x01, 0x01, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0xDD]);

        let decoded = PacketHeader::from_bytes(&bytes).expect("valid header");
        assert_eq!(decoded, header);
    }

    #[test]
    fn test_framed_packet_encode_decode() {
        let opus_frame = vec![0xFC, 0x41, 0x99, 0x00, 0x7F];
        let pkt = FramedPacket::new(
            PacketType::AudioOpus,
            StreamId::PhoneToPc,
            65535,
            12345678,
            opus_frame.clone(),
        );
        let wire = pkt.encode();
        assert_eq!(wire.len(), HEADER_SIZE + opus_frame.len());

        let parsed = FramedPacket::decode(&wire).expect("valid framed packet");
        assert_eq!(parsed.header.packet_type, PacketType::AudioOpus);
        assert_eq!(parsed.header.stream_id, StreamId::PhoneToPc);
        assert_eq!(parsed.header.sequence_num, 65535);
        assert_eq!(parsed.header.timestamp, 12345678);
        assert_eq!(parsed.payload, opus_frame);
    }
}
