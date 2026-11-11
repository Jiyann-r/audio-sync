export interface AudioConfig {
  pc_to_phone_enabled: boolean;
  phone_to_pc_enabled: boolean;
  pc_muted: boolean;
  mic_muted: boolean;
  push_to_talk_enabled: boolean;
  push_to_talk_active: boolean;
  rnnoise_enabled: boolean;
  vad_gate_threshold: number;
  mic_gain_db: number;
  pc_volume: number;
  opus_bitrate_bps: number;
  frame_duration_ms: number;
  jitter_buffer_packets: number;
  virtual_mic_device_hint: string;
}

export interface AudioLevels {
  pc_peak: number;
  pc_rms: number;
  mic_peak: number;
  mic_rms: number;
  vad_probability: number;
}

export interface NetworkStatus {
  local_ip: string;
  udp_port: number;
  mdns_active: boolean;
  connected: boolean;
  peer_address: string | null;
  peer_device_name: string | null;
  rtt_ms: number;
  packets_sent: number;
  packets_received: number;
  packets_lost: number;
}

export interface AppSnapshot {
  config: AudioConfig;
  levels: AudioLevels;
  network: NetworkStatus;
  vbcable_device_name: string;
  vbcable_detected: boolean;
}
