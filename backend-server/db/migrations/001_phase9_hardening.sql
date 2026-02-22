CREATE TABLE IF NOT EXISTS schema_migrations (
  version VARCHAR(64) PRIMARY KEY,
  applied_at TIMESTAMP DEFAULT NOW()
);

ALTER TABLE biometric_profiles ADD COLUMN IF NOT EXISTS std_dev_dwell FLOAT DEFAULT 0;
ALTER TABLE biometric_profiles ADD COLUMN IF NOT EXISTS m2_dwell FLOAT DEFAULT 0;
ALTER TABLE biometric_profiles ADD COLUMN IF NOT EXISTS m2_flight FLOAT DEFAULT 0;

CREATE TABLE IF NOT EXISTS user_sessions (
  id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(id) ON DELETE CASCADE,
  session_token VARCHAR(128) UNIQUE NOT NULL,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS auth_login_attempts (
  id SERIAL PRIMARY KEY,
  username VARCHAR(64) NOT NULL,
  ip_address VARCHAR(64) NOT NULL,
  successful BOOLEAN NOT NULL,
  attempted_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_score_history (
  id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(id) ON DELETE CASCADE,
  score FLOAT NOT NULL,
  outcome VARCHAR(16) NOT NULL,
  coverage_ratio FLOAT,
  matched_pairs INT,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_score_thresholds (
  user_id INT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  success_threshold FLOAT NOT NULL,
  challenge_threshold FLOAT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_auth_attempts_username_ip_time ON auth_login_attempts(username, ip_address, attempted_at);
CREATE INDEX IF NOT EXISTS idx_score_history_user_time ON user_score_history(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_user_sessions_user_expiry ON user_sessions(user_id, expires_at);
CREATE INDEX IF NOT EXISTS idx_user_sessions_expiry ON user_sessions(expires_at);
CREATE INDEX IF NOT EXISTS idx_biometric_profiles_user_pair ON biometric_profiles(user_id, key_pair);
