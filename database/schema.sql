CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL
);

CREATE TABLE biometric_profiles (
    user_id INT REFERENCES users(id),
    key_pair VARCHAR(2),
    avg_flight_time FLOAT,
    std_dev_flight FLOAT,
    avg_dwell_time FLOAT,
    sample_count INT DEFAULT 0 
);

CREATE TABLE access_logs (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    distance_score FLOAT,     
    verdict VARCHAR(10),      
    attempted_at TIMESTAMP DEFAULT NOW()
);