require 'sinatra'
require 'json'
require 'pg'
require 'yaml'
require 'logger'
require 'digest'
require 'securerandom'
require 'bcrypt'
require 'thread'
require_relative 'lib/auth_service'

set :bind, '0.0.0.0'
set :port, 4567

# Configure logging
$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO

AUTH_RATE_LIMIT_MAX = 30
AUTH_RATE_LIMIT_WINDOW_SECONDS = 60
AUTH_LOCKOUT_THRESHOLD = 5
AUTH_LOCKOUT_WINDOW_MINUTES = 15

RATE_LIMIT_MUTEX = Mutex.new
RATE_LIMIT_BUCKETS = {}

# Load Database Configuration
begin
  db_config = File.exist?('config/database.yml') ? YAML.load_file('config/database.yml')['development'] : {}
rescue => e
  $logger.warn "Could not load config/database.yml: #{e.message}"
  db_config = {}
end

DB_NAME = ENV['DB_NAME'] || db_config['database'] || 'biokey_db'
DB_USER = ENV['DB_USER'] || db_config['user'] || 'postgres'
DB_PASS = ENV['DB_PASSWORD'] || db_config['password'] || 'change_me'
DB_HOST = ENV['DB_HOST'] || db_config['host'] || 'localhost'

begin
  DB = PG.connect(
    dbname:   DB_NAME, 
    user:     DB_USER, 
    password: DB_PASS,
    host:     DB_HOST
  )
  $logger.info "Connected to database #{DB_NAME} at #{DB_HOST}"
rescue PG::Error => e
  $logger.error "Unable to connect to database: #{e.message}"
  exit(1)
end

# Helper for JSON Error responses
def json_error(message, status_code = 500)
  status status_code
  { status: "ERROR", message: message }.to_json
end

def valid_username?(username)
  !username.nil? && username.match?(/\A[a-zA-Z0-9_]{3,32}\z/)
end

def valid_password?(password)
  !password.nil? && password.length >= 8 && password.length <= 128
end

def valid_timing_payload?(timings)
  return false unless timings.is_a?(Array)
  return false if timings.empty? || timings.length > 500

  timings.each_with_index do |sample, index|
    normalized = normalize_timing_sample(sample, index)
    return false if normalized.nil?
    return false if normalized[:pair].strip.empty? || normalized[:pair].length > 16
    return false if normalized[:dwell] <= 0 || normalized[:flight] <= 0
    return false if normalized[:dwell] > 5000 || normalized[:flight] > 5000
  end

  true
end

def ensure_user_exists(user_id)
  existing = DB.exec_params("SELECT id FROM users WHERE id = $1 LIMIT 1", [user_id])
  return if existing.ntuples > 0

  DB.exec_params(
    "INSERT INTO users (id, username, password_hash) VALUES ($1, $2, $3)",
    [user_id, "user_#{user_id}", hash_password(SecureRandom.hex(24))]
  )
end

def normalize_timing_sample(sample, index)
  if sample.is_a?(Hash)
    pair = sample['pair'] || "k#{index}"
    dwell = sample['dwell'] || sample['value'] || sample['time']
    flight = sample['flight'] || sample['dwell'] || sample['value'] || sample['time']

    return nil if dwell.nil? || flight.nil?

    return {
      pair: pair.to_s,
      dwell: dwell.to_f,
      flight: flight.to_f
    }
  end

  if sample.is_a?(Numeric)
    return {
      pair: "k#{index}",
      dwell: sample.to_f,
      flight: sample.to_f
    }
  end

  nil
end

def update_running_stats(old_mean, old_m2, old_count, new_value)
  new_count = old_count + 1
  delta = new_value - old_mean
  new_mean = old_mean + (delta / new_count)
  delta2 = new_value - new_mean
  new_m2 = old_m2 + (delta * delta2)
  new_std = new_count > 1 ? Math.sqrt(new_m2 / (new_count - 1)) : 0.0

  {
    mean: new_mean,
    m2: new_m2,
    count: new_count,
    std: new_std
  }
end

def upsert_biometric_pair(user_id, pair, dwell, flight)
  DB.transaction do |conn|
    current = conn.exec_params(
      "SELECT avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count, m2_dwell, m2_flight
       FROM biometric_profiles
       WHERE user_id = $1 AND key_pair = $2
       FOR UPDATE",
      [user_id, pair]
    )

    if current.ntuples == 0
      conn.exec_params(
        "INSERT INTO biometric_profiles (
           user_id, key_pair, avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count, m2_dwell, m2_flight
         ) VALUES ($1, $2, $3, $4, 0, 0, 1, 0, 0)",
        [user_id, pair, dwell, flight]
      )
      next
    end

    row = current[0]
    sample_count = row['sample_count'].to_i

    dwell_stats = update_running_stats(
      row['avg_dwell_time'].to_f,
      row['m2_dwell'].to_f,
      sample_count,
      dwell
    )

    flight_stats = update_running_stats(
      row['avg_flight_time'].to_f,
      row['m2_flight'].to_f,
      sample_count,
      flight
    )

    conn.exec_params(
      "UPDATE biometric_profiles
       SET avg_dwell_time = $1,
           avg_flight_time = $2,
           std_dev_dwell = $3,
           std_dev_flight = $4,
           sample_count = $5,
           m2_dwell = $6,
           m2_flight = $7
       WHERE user_id = $8 AND key_pair = $9",
      [
        dwell_stats[:mean],
        flight_stats[:mean],
        dwell_stats[:std],
        flight_stats[:std],
        dwell_stats[:count],
        dwell_stats[:m2],
        flight_stats[:m2],
        user_id,
        pair
      ]
    )
  end
end

# Route 1: The Enrollment (Training)
post '/train' do
  content_type :json
  begin
    data = JSON.parse(request.body.read)
    user_id = data['user_id']&.to_i
    timings = data['timings']

    if user_id.nil? || user_id <= 0 || !valid_timing_payload?(timings)
       return json_error("Invalid input data", 400)
    end

    ensure_user_exists(user_id)

    timings.each_with_index do |t, index|
      sample = normalize_timing_sample(t, index)
      next if sample.nil?

      upsert_biometric_pair(user_id, sample[:pair], sample[:dwell], sample[:flight])
    end
    $logger.info "Updated profile for User ID #{user_id}"
    { status: "Profile Updated" }.to_json

  rescue JSON::ParserError
    json_error("Invalid JSON format", 400)
  rescue PG::Error => e
    $logger.error "Database error in /train: #{e.message}"
    json_error("Database error")
  rescue => e
    $logger.error "Unknown error in /train: #{e.message}"
    json_error("Internal Server Error")
  end
end

# Route 2: The Login (Verification)
get '/login' do
  "Hello World"
end

post '/login' do
  content_type :json
  begin
    data = JSON.parse(request.body.read)
    user_id = data['user_id']&.to_i
    timings = data['timings']
    
    if user_id.nil? || user_id <= 0 || !valid_timing_payload?(timings)
      return json_error("Missing user_id or timings", 400)
    end

    result = AuthService.verify_login(user_id, timings)

    verdict_code = case result[:status]
             when 'SUCCESS' then 'BIO_OK'
             when 'CHALLENGE' then 'BIO_CHAL'
             when 'DENIED' then 'BIO_DENY'
             else 'BIO_ERR'
             end
    log_access_event(user_id: user_id, verdict: verdict_code, score: result[:score])
    
    # Log the result status
    $logger.info "Login attempt for User #{user_id}: #{result[:status]} (Score: #{result[:score]})"
    
    result.to_json

  rescue JSON::ParserError
    json_error("Invalid JSON format", 400)
  rescue PG::Error => e
    $logger.error "Database error in /login: #{e.message}"
    json_error("Database error")
  rescue => e
    $logger.error "Unknown error in /login: #{e.message}"
    json_error("Internal Server Error")
  end
end

begin
  DB.exec("ALTER TABLE biometric_profiles ADD COLUMN IF NOT EXISTS std_dev_dwell FLOAT DEFAULT 0")
  DB.exec("ALTER TABLE biometric_profiles ADD COLUMN IF NOT EXISTS m2_dwell FLOAT DEFAULT 0")
  DB.exec("ALTER TABLE biometric_profiles ADD COLUMN IF NOT EXISTS m2_flight FLOAT DEFAULT 0")

  DB.exec(
    "CREATE TABLE IF NOT EXISTS user_sessions (
      id SERIAL PRIMARY KEY,
      user_id INT REFERENCES users(id) ON DELETE CASCADE,
      session_token VARCHAR(128) UNIQUE NOT NULL,
      expires_at TIMESTAMP NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    )"
  )

  DB.exec(
    "CREATE TABLE IF NOT EXISTS auth_login_attempts (
      id SERIAL PRIMARY KEY,
      username VARCHAR(64) NOT NULL,
      ip_address VARCHAR(64) NOT NULL,
      successful BOOLEAN NOT NULL,
      attempted_at TIMESTAMP DEFAULT NOW()
    )"
  )

  DB.exec(
    "CREATE TABLE IF NOT EXISTS user_score_history (
      id SERIAL PRIMARY KEY,
      user_id INT REFERENCES users(id) ON DELETE CASCADE,
      score FLOAT NOT NULL,
      outcome VARCHAR(16) NOT NULL,
      coverage_ratio FLOAT,
      matched_pairs INT,
      created_at TIMESTAMP DEFAULT NOW()
    )"
  )

  DB.exec(
    "CREATE TABLE IF NOT EXISTS user_score_thresholds (
      user_id INT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      success_threshold FLOAT NOT NULL,
      challenge_threshold FLOAT NOT NULL,
      updated_at TIMESTAMP DEFAULT NOW()
    )"
  )

  DB.exec("CREATE INDEX IF NOT EXISTS idx_auth_attempts_username_ip_time ON auth_login_attempts(username, ip_address, attempted_at)")
  DB.exec("CREATE INDEX IF NOT EXISTS idx_score_history_user_time ON user_score_history(user_id, created_at)")
rescue PG::Error => e
  $logger.error "Unable to create auth/session support tables: #{e.message}"
  exit(1)
end

def hash_password(password)
  pepper = ENV['APP_AUTH_PEPPER'] || 'biokey_dev_pepper'
  BCrypt::Password.create("#{pepper}:#{password}").to_s
end

def legacy_hash_password(password)
  salt = ENV['APP_AUTH_SALT'] || 'biokey_dev_salt'
  Digest::SHA256.hexdigest("#{salt}:#{password}")
end

def bcrypt_hash?(value)
  value.is_a?(String) && value.start_with?('$2a$', '$2b$', '$2y$')
end

def password_matches?(password, stored_hash)
  return false if stored_hash.nil? || stored_hash.empty?

  if bcrypt_hash?(stored_hash)
    pepper = ENV['APP_AUTH_PEPPER'] || 'biokey_dev_pepper'
    BCrypt::Password.new(stored_hash) == "#{pepper}:#{password}"
  else
    legacy_hash_password(password) == stored_hash
  end
rescue BCrypt::Errors::InvalidHash
  false
end

def cleanup_expired_sessions
  DB.exec("DELETE FROM user_sessions WHERE expires_at <= NOW()")
end

def revoke_user_sessions(user_id, except_token = nil)
  if except_token.nil?
    DB.exec_params('DELETE FROM user_sessions WHERE user_id = $1', [user_id])
  else
    DB.exec_params('DELETE FROM user_sessions WHERE user_id = $1 AND session_token <> $2', [user_id, except_token])
  end
end

def generate_session_token
  SecureRandom.hex(32)
end

def bearer_token
  auth_header = request.env['HTTP_AUTHORIZATION']
  return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

  auth_header.split(' ', 2).last
end

def active_session_for(token)
  return nil if token.nil? || token.empty?

  result = DB.exec_params(
    "SELECT s.user_id, u.username
     FROM user_sessions s
     JOIN users u ON u.id = s.user_id
     WHERE s.session_token = $1 AND s.expires_at > NOW()
     LIMIT 1",
    [token]
  )

  return nil if result.ntuples == 0

  result[0]
end

post '/auth/register' do
  content_type :json
  begin
    ip_address = client_ip
    if rate_limited?('auth-register-ip', ip_address, limit: AUTH_RATE_LIMIT_MAX, window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS)
      log_access_event(user_id: nil, verdict: 'REG_RATE', score: nil)
      return json_error('Too many requests. Try again shortly.', 429)
    end

    data = JSON.parse(request.body.read)
    username = data['username']&.strip
    password = data['password']

    if !valid_username?(username)
      return json_error('Username must be 3-32 chars (letters, numbers, underscore)', 400)
    end

    if !valid_password?(password)
      return json_error('Password must be between 8 and 128 chars', 400)
    end

    DB.exec_params(
      'INSERT INTO users (username, password_hash) VALUES ($1, $2)',
      [username, hash_password(password)]
    )

    created_user = DB.exec_params('SELECT id FROM users WHERE username = $1 LIMIT 1', [username])
    user_id = created_user.ntuples > 0 ? created_user[0]['id'].to_i : nil
    log_access_event(user_id: user_id, verdict: 'REG_OK', score: nil)

    { status: 'SUCCESS', message: 'Account created' }.to_json
  rescue PG::UniqueViolation
    log_access_event(user_id: nil, verdict: 'REG_FAIL', score: nil)
    json_error('Username already exists', 409)
  rescue JSON::ParserError
    log_access_event(user_id: nil, verdict: 'REG_FAIL', score: nil)
    json_error('Invalid JSON format', 400)
  rescue PG::Error => e
    $logger.error "Database error in /auth/register: #{e.message}"
    log_access_event(user_id: nil, verdict: 'REG_FAIL', score: nil)
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/register: #{e.message}"
    log_access_event(user_id: nil, verdict: 'REG_FAIL', score: nil)
    json_error('Internal Server Error')
  end
end

post '/auth/login' do
  content_type :json
  begin
    ip_address = client_ip
    if rate_limited?('auth-login-ip', ip_address, limit: AUTH_RATE_LIMIT_MAX, window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS)
      log_access_event(user_id: nil, verdict: 'AUTH_RATE', score: nil)
      return json_error('Too many requests. Try again shortly.', 429)
    end

    data = JSON.parse(request.body.read)
    username = data['username']&.strip
    password = data['password']

    if !valid_username?(username) || password.nil? || password.empty?
      record_login_attempt(username.to_s, ip_address, false)
      log_access_event(user_id: nil, verdict: 'AUTH_FAIL', score: nil)
      return json_error('Missing username or password', 400)
    end

    if login_locked_out?(username, ip_address)
      log_access_event(user_id: nil, verdict: 'AUTH_LOCK', score: nil)
      return json_error('Account temporarily locked due to repeated failures', 423)
    end

    result = DB.exec_params(
      'SELECT id, password_hash FROM users WHERE username = $1 LIMIT 1',
      [username]
    )

    if result.ntuples == 0 || !password_matches?(password, result[0]['password_hash'])
      record_login_attempt(username, ip_address, false)
      log_access_event(user_id: nil, verdict: 'AUTH_FAIL', score: nil)
      return json_error('Invalid credentials', 401)
    end

    user_id = result[0]['id'].to_i
    stored_hash = result[0]['password_hash']

    if !bcrypt_hash?(stored_hash)
      DB.exec_params(
        'UPDATE users SET password_hash = $1 WHERE id = $2',
        [hash_password(password), user_id]
      )
    end

    cleanup_expired_sessions
    revoke_user_sessions(user_id)
    record_login_attempt(username, ip_address, true)
    clear_login_failures(username, ip_address)

    token = generate_session_token
    expires_at = (Time.now + 24 * 60 * 60).utc

    DB.exec_params(
      'INSERT INTO user_sessions (user_id, session_token, expires_at) VALUES ($1, $2, $3)',
      [user_id, token, expires_at]
    )

    log_access_event(user_id: user_id, verdict: 'AUTH_OK', score: nil)

    {
      status: 'SUCCESS',
      token: token,
      user_id: user_id,
      username: username,
      expires_at: expires_at
    }.to_json
  rescue JSON::ParserError
    log_access_event(user_id: nil, verdict: 'AUTH_FAIL', score: nil)
    json_error('Invalid JSON format', 400)
  rescue PG::Error => e
    $logger.error "Database error in /auth/login: #{e.message}"
    log_access_event(user_id: nil, verdict: 'AUTH_FAIL', score: nil)
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/login: #{e.message}"
    log_access_event(user_id: nil, verdict: 'AUTH_FAIL', score: nil)
    json_error('Internal Server Error')
  end
end

get '/auth/profile' do
  content_type :json
  begin
    session = active_session_for(bearer_token)
    return json_error('Unauthorized', 401) if session.nil?

    user_id = session['user_id'].to_i
    profile_count = DB.exec_params(
      'SELECT COUNT(*) AS c FROM biometric_profiles WHERE user_id = $1',
      [user_id]
    )[0]['c'].to_i

    {
      status: 'SUCCESS',
      user_id: user_id,
      username: session['username'],
      biometric_pairs: profile_count
    }.to_json
  rescue PG::Error => e
    $logger.error "Database error in /auth/profile: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/profile: #{e.message}"
    json_error('Internal Server Error')
  end
end

post '/auth/logout' do
  content_type :json
  begin
    token = bearer_token
    if token.nil?
      log_access_event(user_id: nil, verdict: 'LOG_FAIL', score: nil)
      return json_error('Missing authorization token', 401)
    end

    session = active_session_for(token)
    DB.exec_params('DELETE FROM user_sessions WHERE session_token = $1', [token])
    log_access_event(user_id: session.nil? ? nil : session['user_id'].to_i, verdict: 'LOGOUT', score: nil)
    { status: 'SUCCESS', message: 'Logged out' }.to_json
  rescue PG::Error => e
    $logger.error "Database error in /auth/logout: #{e.message}"
    log_access_event(user_id: nil, verdict: 'LOG_FAIL', score: nil)
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/logout: #{e.message}"
    log_access_event(user_id: nil, verdict: 'LOG_FAIL', score: nil)
    json_error('Internal Server Error')
  end
end

post '/auth/refresh' do
  content_type :json
  begin
    token = bearer_token
    if token.nil?
      log_access_event(user_id: nil, verdict: 'REF_FAIL', score: nil)
      return json_error('Missing authorization token', 401)
    end

    session = active_session_for(token)
    if session.nil?
      log_access_event(user_id: nil, verdict: 'REF_FAIL', score: nil)
      return json_error('Unauthorized', 401)
    end

    cleanup_expired_sessions
    revoke_user_sessions(session['user_id'].to_i, token)

    new_token = generate_session_token
    new_expires_at = (Time.now + 24 * 60 * 60).utc

    updated = DB.exec_params(
      'UPDATE user_sessions SET session_token = $1, expires_at = $2 WHERE session_token = $3',
      [new_token, new_expires_at, token]
    )

    if updated.cmd_tuples == 0
      log_access_event(user_id: nil, verdict: 'REF_FAIL', score: nil)
      return json_error('Unauthorized', 401)
    end

    log_access_event(user_id: session['user_id'].to_i, verdict: 'REF_OK', score: nil)

    {
      status: 'SUCCESS',
      token: new_token,
      user_id: session['user_id'].to_i,
      username: session['username'],
      expires_at: new_expires_at
    }.to_json
  rescue PG::Error => e
    $logger.error "Database error in /auth/refresh: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/refresh: #{e.message}"
    json_error('Internal Server Error')
  end
end

def client_ip
  forwarded = request.env['HTTP_X_FORWARDED_FOR']
  return forwarded.split(',').first.strip unless forwarded.nil? || forwarded.strip.empty?

  request.ip.to_s
end

def rate_limited?(scope, key, limit:, window_seconds:)
  now = Time.now.to_i
  bucket_key = "#{scope}:#{key}"

  RATE_LIMIT_MUTEX.synchronize do
    bucket = RATE_LIMIT_BUCKETS[bucket_key] || []
    cutoff = now - window_seconds
    bucket = bucket.select { |ts| ts > cutoff }

    if bucket.length >= limit
      RATE_LIMIT_BUCKETS[bucket_key] = bucket
      return true
    end

    bucket << now
    RATE_LIMIT_BUCKETS[bucket_key] = bucket
    false
  end
end

def log_access_event(user_id:, verdict:, score: nil)
  DB.exec_params(
    'INSERT INTO access_logs (user_id, distance_score, verdict) VALUES ($1, $2, $3)',
    [user_id, score, verdict.to_s[0, 10]]
  )
rescue PG::Error => e
  $logger.warn "Failed to log access event #{verdict}: #{e.message}"
end

def record_login_attempt(username, ip_address, successful)
  DB.exec_params(
    'INSERT INTO auth_login_attempts (username, ip_address, successful) VALUES ($1, $2, $3)',
    [username, ip_address, successful]
  )
rescue PG::Error => e
  $logger.warn "Failed to record login attempt for #{username}@#{ip_address}: #{e.message}"
end

def clear_login_failures(username, ip_address)
  DB.exec_params(
    "DELETE FROM auth_login_attempts
     WHERE username = $1 AND ip_address = $2 AND successful = FALSE",
    [username, ip_address]
  )
rescue PG::Error => e
  $logger.warn "Failed to clear login failures for #{username}@#{ip_address}: #{e.message}"
end

def login_locked_out?(username, ip_address)
  result = DB.exec_params(
    "SELECT COUNT(*) AS c
     FROM auth_login_attempts
     WHERE username = $1
       AND ip_address = $2
       AND successful = FALSE
       AND attempted_at > NOW() - INTERVAL '#{AUTH_LOCKOUT_WINDOW_MINUTES} minutes'",
    [username, ip_address]
  )

  result[0]['c'].to_i >= AUTH_LOCKOUT_THRESHOLD
rescue PG::Error => e
  $logger.warn "Failed to evaluate lockout for #{username}@#{ip_address}: #{e.message}"
  false
end