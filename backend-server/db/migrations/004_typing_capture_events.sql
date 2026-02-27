CREATE TABLE IF NOT EXISTS typing_capture_events (
  id BIGSERIAL PRIMARY KEY,
  user_id INT REFERENCES users(id) ON DELETE SET NULL,
  context VARCHAR(64) NOT NULL,
  field_name VARCHAR(64) NOT NULL,
  client_session_id VARCHAR(64) NOT NULL,
  event_type VARCHAR(24) NOT NULL,
  key_value VARCHAR(64),
  key_code INT,
  dwell_ms FLOAT,
  flight_ms FLOAT,
  typed_length INT,
  cursor_pos INT,
  client_ts_ms BIGINT,
  ip_address TEXT,
  request_id VARCHAR(64),
  metadata JSONB DEFAULT '{}'::jsonb,
  captured_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_typing_capture_user_time
  ON typing_capture_events(user_id, captured_at DESC);

CREATE INDEX IF NOT EXISTS idx_typing_capture_context_time
  ON typing_capture_events(context, captured_at DESC);

CREATE INDEX IF NOT EXISTS idx_typing_capture_session_time
  ON typing_capture_events(client_session_id, captured_at DESC);
