CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(50) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL
);

CREATE TABLE IF NOT EXISTS biometric_profiles (
  user_id INT REFERENCES users(id) ON DELETE CASCADE,
  key_pair VARCHAR(16),
  avg_dwell_time FLOAT,
  avg_flight_time FLOAT,
  std_dev_dwell FLOAT DEFAULT 0,
  std_dev_flight FLOAT DEFAULT 0,
  sample_count INT DEFAULT 0,
  m2_dwell FLOAT DEFAULT 0,
  m2_flight FLOAT DEFAULT 0,
  UNIQUE (user_id, key_pair)
);

CREATE TABLE IF NOT EXISTS access_logs (
  id SERIAL PRIMARY KEY,
  user_id INT REFERENCES users(id) ON DELETE SET NULL,
  distance_score FLOAT,
  verdict VARCHAR(10),
  attempted_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_access_logs_user_time ON access_logs(user_id, attempted_at DESC);
CREATE INDEX IF NOT EXISTS idx_biometric_profiles_user_pair ON biometric_profiles(user_id, key_pair);
