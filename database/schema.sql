CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL
);

CREATE TABLE biometric_profiles (
    user_id INT REFERENCES users(id),
    key_pair VARCHAR(10),
    avg_flight_time FLOAT,
    std_dev_dwell FLOAT DEFAULT 0,
    std_dev_flight FLOAT,
    avg_dwell_time FLOAT,
    sample_count INT DEFAULT 0,
    m2_dwell FLOAT DEFAULT 0,
    m2_flight FLOAT DEFAULT 0,
    UNIQUE (user_id, key_pair) 
);

CREATE TABLE access_logs (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    distance_score FLOAT,     
    verdict VARCHAR(10),      
    attempted_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE user_score_history (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id) ON DELETE CASCADE,
    score FLOAT NOT NULL,
    outcome VARCHAR(16) NOT NULL,
    coverage_ratio FLOAT,
    matched_pairs INT,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE user_score_thresholds (
    user_id INT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    success_threshold FLOAT NOT NULL,
    challenge_threshold FLOAT NOT NULL,
    updated_at TIMESTAMP DEFAULT NOW()
);