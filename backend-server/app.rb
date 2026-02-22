require 'sinatra'
require 'json'
require 'pg'
require 'yaml'
require 'logger'
require 'digest'
require 'securerandom'
require_relative 'lib/auth_service'

set :bind, '0.0.0.0'
set :port, 4567

# Configure logging
$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO

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
    [user_id, "user_#{user_id}", "demo_password_hash"]
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

      # Use ON CONFLICT to update the existing rhythm and increment the count
      # Note: Requires a UNIQUE constraint on (user_id, key_pair) in your schema
      DB.exec_params(
        "INSERT INTO biometric_profiles (user_id, key_pair, avg_dwell_time, avg_flight_time, sample_count) 
         VALUES ($1, $2, $3, $4, 1)
         ON CONFLICT (user_id, key_pair) 
         DO UPDATE SET 
           avg_dwell_time = (biometric_profiles.avg_dwell_time + EXCLUDED.avg_dwell_time) / 2,
           avg_flight_time = (biometric_profiles.avg_flight_time + EXCLUDED.avg_flight_time) / 2,
           sample_count = biometric_profiles.sample_count + 1", 
        [user_id, sample[:pair], sample[:dwell], sample[:flight]]
      )
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
  DB.exec(
    "CREATE TABLE IF NOT EXISTS user_sessions (
      id SERIAL PRIMARY KEY,
      user_id INT REFERENCES users(id) ON DELETE CASCADE,
      session_token VARCHAR(128) UNIQUE NOT NULL,
      expires_at TIMESTAMP NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    )"
  )
rescue PG::Error => e
  $logger.error "Unable to create user_sessions table: #{e.message}"
  exit(1)
end

def hash_password(password)
  salt = ENV['APP_AUTH_SALT'] || 'biokey_dev_salt'
  Digest::SHA256.hexdigest("#{salt}:#{password}")
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

    { status: 'SUCCESS', message: 'Account created' }.to_json
  rescue PG::UniqueViolation
    json_error('Username already exists', 409)
  rescue JSON::ParserError
    json_error('Invalid JSON format', 400)
  rescue PG::Error => e
    $logger.error "Database error in /auth/register: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/register: #{e.message}"
    json_error('Internal Server Error')
  end
end

post '/auth/login' do
  content_type :json
  begin
    data = JSON.parse(request.body.read)
    username = data['username']&.strip
    password = data['password']

    if !valid_username?(username) || password.nil? || password.empty?
      return json_error('Missing username or password', 400)
    end

    result = DB.exec_params(
      'SELECT id, password_hash FROM users WHERE username = $1 LIMIT 1',
      [username]
    )

    if result.ntuples == 0 || result[0]['password_hash'] != hash_password(password)
      return json_error('Invalid credentials', 401)
    end

    user_id = result[0]['id'].to_i
    token = generate_session_token
    expires_at = (Time.now + 24 * 60 * 60).utc

    DB.exec_params(
      'INSERT INTO user_sessions (user_id, session_token, expires_at) VALUES ($1, $2, $3)',
      [user_id, token, expires_at]
    )

    {
      status: 'SUCCESS',
      token: token,
      user_id: user_id,
      username: username,
      expires_at: expires_at
    }.to_json
  rescue JSON::ParserError
    json_error('Invalid JSON format', 400)
  rescue PG::Error => e
    $logger.error "Database error in /auth/login: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/login: #{e.message}"
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
      return json_error('Missing authorization token', 401)
    end

    DB.exec_params('DELETE FROM user_sessions WHERE session_token = $1', [token])
    { status: 'SUCCESS', message: 'Logged out' }.to_json
  rescue PG::Error => e
    $logger.error "Database error in /auth/logout: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/logout: #{e.message}"
    json_error('Internal Server Error')
  end
end

post '/auth/refresh' do
  content_type :json
  begin
    token = bearer_token
    return json_error('Missing authorization token', 401) if token.nil?

    session = active_session_for(token)
    return json_error('Unauthorized', 401) if session.nil?

    new_token = generate_session_token
    new_expires_at = (Time.now + 24 * 60 * 60).utc

    updated = DB.exec_params(
      'UPDATE user_sessions SET session_token = $1, expires_at = $2 WHERE session_token = $3',
      [new_token, new_expires_at, token]
    )

    return json_error('Unauthorized', 401) if updated.cmd_tuples == 0

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