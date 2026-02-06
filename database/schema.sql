-- 1. Users Table: Standard authentication fallback [cite: 132, 136]
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL
);

-- 2. Biometric Profiles Table: The "Unicorn" data [cite: 138, 140]
-- This stores the statistical average timing for each key-to-key transition
CREATE TABLE biometric_profiles (
    user_id INT REFERENCES users(id),
    key_pair VARCHAR(2),      -- e.g., 'H-E' (Flight time from H to E) [cite: 142]
    avg_flight_time FLOAT,    -- e.g., 140.5 ms [cite: 143]
    std_dev_flight FLOAT,     -- Consistency: How much the user varies [cite: 144]
    avg_dwell_time FLOAT,     -- How long the key is held down [cite: 145]
    sample_count INT DEFAULT 0 -- How many times we have recorded this pair [cite: 146]
);

-- 3. Access Logs: For security auditing and analytics [cite: 148, 149]
CREATE TABLE access_logs (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    distance_score FLOAT,     -- The Euclidean score from the C engine [cite: 152]
    verdict VARCHAR(10),      -- 'GRANTED' or 'DENIED' [cite: 153]
    attempted_at TIMESTAMP DEFAULT NOW() [cite: 154]
);