# frozen_string_literal: true

# Timing constants for the Comfier agent protocol (see docs/agent frontend plan).
module AgentTiming
  HEARTBEAT_S = 10
  OFFLINE_AFTER_S = 30
  LEASE_GRACE_S = 120
  ASSIGN_ACK_TIMEOUT_S = 30
  CANCEL_TIMEOUT_S = 60
  RECONCILE_WAIT_S = 10
  REBALANCE_INTERVAL_S = 15
  WARM_WINDOW_S = 600
  MAX_INFRA_RETRIES = 1

  HELLO_TIMEOUT_S = 10
  MAX_MESSAGE_BYTES = 1.megabyte
  MAX_MESSAGES_PER_SECOND = 50
  # Messages an agent may send at once on top of the rate: a reconnect sends hello, inventory, object_info
  # chunks, status and up to 50 buffered job and download results back to back.
  MAX_MESSAGE_BURST = 150
  MIN_FREE_DISK_GB = 10
end
