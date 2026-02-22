CREATE TABLE IF NOT EXISTS audit_events (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMP DEFAULT NOW(),
  event_type VARCHAR(64) NOT NULL,
  actor VARCHAR(64) NOT NULL,
  user_id INT REFERENCES users(id) ON DELETE SET NULL,
  ip_address VARCHAR(64),
  request_id VARCHAR(64),
  metadata JSONB
);

CREATE TABLE IF NOT EXISTS biometric_attempts (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMP DEFAULT NOW(),
  user_id INT REFERENCES users(id) ON DELETE CASCADE,
  outcome VARCHAR(24) NOT NULL,
  score FLOAT,
  coverage_ratio FLOAT,
  matched_pairs INT,
  payload_hash VARCHAR(128),
  ip_address VARCHAR(64),
  request_id VARCHAR(64),
  label VARCHAR(16)
);

CREATE TABLE IF NOT EXISTS evaluation_reports (
  id SERIAL PRIMARY KEY,
  created_at TIMESTAMP DEFAULT NOW(),
  report_type VARCHAR(64) NOT NULL,
  sample_count INT DEFAULT 0,
  far FLOAT,
  frr FLOAT,
  metadata JSONB
);

CREATE INDEX IF NOT EXISTS idx_audit_events_created_type ON audit_events(created_at DESC, event_type);
CREATE INDEX IF NOT EXISTS idx_audit_events_user_time ON audit_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bio_attempts_user_time ON biometric_attempts(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bio_attempts_outcome_time ON biometric_attempts(outcome, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bio_attempts_request_id ON biometric_attempts(request_id);
CREATE INDEX IF NOT EXISTS idx_eval_reports_created ON evaluation_reports(created_at DESC);
