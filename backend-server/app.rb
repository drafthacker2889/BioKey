require 'sinatra'
require 'json'
require 'pg'
require 'yaml'
require 'logger'
require 'digest'
require 'securerandom'
require 'bcrypt'
require 'thread'
require 'time'
require_relative 'lib/auth_service'
require_relative 'lib/dashboard_service'
require_relative 'lib/evaluation_service'

class ApiVersionMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    path = env['PATH_INFO'].to_s
    if path.start_with?('/v1/')
      env['PATH_INFO'] = path.sub('/v1', '')
      env['BIOKEY_API_VERSION'] = 'v1'
    else
      env['BIOKEY_API_VERSION'] = 'legacy'
    end

    @app.call(env)
  end
end

set :bind, '0.0.0.0'
set :port, 4567
set :sessions, true
set :session_secret, ENV['APP_SESSION_SECRET'] || 'biokey_dev_session_secret_change_me_0123456789abcdef0123456789ab'
use ApiVersionMiddleware

# Configure logging
$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO

AUTH_RATE_LIMIT_MAX = 30
AUTH_RATE_LIMIT_WINDOW_SECONDS = 60
AUTH_LOCKOUT_THRESHOLD = 5
AUTH_LOCKOUT_WINDOW_MINUTES = 15
APP_BOOT_TIME = Time.now

RATE_LIMIT_MUTEX = Mutex.new
RATE_LIMIT_BUCKETS = {}

before do
  request_id = request.env['HTTP_X_REQUEST_ID']
  request_id = SecureRandom.hex(12) if request_id.nil? || request_id.strip.empty?

  request.env['BIOKEY_REQUEST_ID'] = request_id
  request.env['BIOKEY_API_VERSION'] ||= 'legacy'

  headers 'X-Request-Id' => request_id
  headers 'X-Api-Version' => request.env['BIOKEY_API_VERSION']
  headers 'X-Api-Deprecation' => 'Legacy paths are supported; prefer /v1/*' if request.env['BIOKEY_API_VERSION'] == 'legacy'
  headers 'X-Content-Type-Options' => 'nosniff'
  headers 'X-Frame-Options' => 'DENY'
  headers 'Referrer-Policy' => 'no-referrer'

  if request.secure? || request.env['HTTP_X_FORWARDED_PROTO'] == 'https'
    headers 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
  end

  if ENV['APP_REQUIRE_HTTPS'] == 'true'
    secure = request.secure? || request.env['HTTP_X_FORWARDED_PROTO'] == 'https'
    unless secure
      content_type :json
      halt 426, json_error('HTTPS required for this environment', 426, 'HTTPS_REQUIRED')
    end
  end
end

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

def current_request_id
  request.env['BIOKEY_REQUEST_ID']
rescue
  'n/a'
end

def current_api_version
  request.env['BIOKEY_API_VERSION'] || 'legacy'
rescue
  'legacy'
end

def localhost_request?
  ip = request.ip.to_s
  return true if ['127.0.0.1', '::1', 'localhost'].include?(ip)

  return false unless ENV['TRUST_PROXY'] == '1'

  forwarded = request.env['HTTP_X_FORWARDED_FOR'].to_s
  forwarded.split(',').map(&:strip).any? { |part| ['127.0.0.1', '::1', 'localhost'].include?(part) }
end

def ensure_required_tables!
  required_tables = %w[
    users
    biometric_profiles
    access_logs
    user_sessions
    auth_login_attempts
    user_score_history
    user_score_thresholds
    audit_events
    biometric_attempts
    evaluation_reports
  ]

  missing = required_tables.select do |table_name|
    DB.exec_params('SELECT to_regclass($1) AS table_ref', [table_name])[0]['table_ref'].nil?
  end

  return if missing.empty?

  $logger.error "Missing required tables: #{missing.join(', ')}"
  $logger.error "Run migrations first: cd backend-server && ruby db/migrate.rb"
  exit(1)
end

def admin_username
  ENV['ADMIN_USER'] || 'admin'
end

def admin_password_hash
  ENV['ADMIN_PASSWORD_HASH'].to_s
end

def admin_token
  ENV['ADMIN_TOKEN'].to_s
end

def admin_authenticated?
  session[:admin_user] == admin_username
end

def admin_token_valid?
  token = request.env['HTTP_X_ADMIN_TOKEN'].to_s
  !admin_token.empty? && token == admin_token
end

def can_read_dashboard?
  localhost_request? || admin_authenticated? || admin_token_valid?
end

def can_control_dashboard?
  admin_authenticated? || admin_token_valid?
end

def verify_admin_password(password)
  return false if password.nil? || password.empty? || admin_password_hash.empty?

  BCrypt::Password.new(admin_password_hash) == password
rescue BCrypt::Errors::InvalidHash
  false
end

def require_dashboard_read!
  return if can_read_dashboard?

  content_type :json if request.path_info.start_with?('/admin/api')
  halt 403, (request.path_info.start_with?('/admin/api') ? json_error('Dashboard read access denied', 403, 'ADMIN_READ_FORBIDDEN') : 'Forbidden')
end

def require_dashboard_control!
  return if can_control_dashboard?

  content_type :json
  halt 403, json_error('Dashboard control access denied', 403, 'ADMIN_CONTROL_FORBIDDEN')
end

def normalize_attempt_label(value)
  label = value.to_s.strip.upcase
  return nil if label.empty? || label == 'UNLABELED'
  return label if %w[GENUINE IMPOSTER].include?(label)

  :invalid
end

def json_success(payload = {}, status_code = 200)
  status status_code
  body = payload.is_a?(Hash) ? payload : { data: payload }
  body[:request_id] = current_request_id
  body[:api_version] = current_api_version
  body[:timestamp] = Time.now.utc.iso8601
  body.to_json
end

def json_error(message, status_code = 500, code = 'ERROR', details = nil)
  status status_code
  error_body = {
    status: 'ERROR',
    error: {
      code: code,
      message: message
    },
    request_id: current_request_id,
    api_version: current_api_version,
    timestamp: Time.now.utc.iso8601
  }
  error_body[:error][:details] = details unless details.nil?
  error_body.to_json
end

def log_audit_event(event_type:, actor: 'system', user_id: nil, metadata: {})
  DB.exec_params(
    'INSERT INTO audit_events (event_type, actor, user_id, ip_address, request_id, metadata) VALUES ($1, $2, $3, $4, $5, $6::jsonb)',
    [
      event_type.to_s[0, 64],
      actor.to_s[0, 64],
      user_id,
      client_ip,
      current_request_id,
      metadata.to_json
    ]
  )
rescue PG::Error => e
  $logger.warn "Failed to write audit event #{event_type}: #{e.message}"
end

def log_biometric_attempt(user_id:, outcome:, score:, coverage_ratio:, matched_pairs:, timings: nil)
  payload_hash = begin
    timings.nil? ? nil : Digest::SHA256.hexdigest(timings.to_json)
  rescue
    nil
  end

  DB.exec_params(
    'INSERT INTO biometric_attempts (user_id, outcome, score, coverage_ratio, matched_pairs, payload_hash, ip_address, request_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
    [
      user_id,
      outcome.to_s[0, 24],
      score,
      coverage_ratio,
      matched_pairs,
      payload_hash,
      client_ip,
      current_request_id
    ]
  )
rescue PG::Error => e
  $logger.warn "Failed to write biometric attempt for user #{user_id}: #{e.message}"
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
    json_success({ status: 'SUCCESS', message: 'Profile Updated' })

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

    if result[:status] == 'ERROR'
      details = result.dup
      details.delete(:status)
      message = details.delete(:message) || 'Biometric verification failed'
      log_biometric_attempt(
        user_id: user_id,
        outcome: 'ERROR',
        score: result[:score],
        coverage_ratio: result[:coverage_ratio],
        matched_pairs: result[:matched_pairs],
        timings: timings
      )
      log_access_event(user_id: user_id, verdict: 'BIO_ERR', score: result[:score])
      return json_error(message, 422, 'BIOMETRIC_VALIDATION_FAILED', details)
    end

    verdict_code = case result[:status]
             when 'SUCCESS' then 'BIO_OK'
             when 'CHALLENGE' then 'BIO_CHAL'
             when 'DENIED' then 'BIO_DENY'
             else 'BIO_ERR'
             end
    log_access_event(user_id: user_id, verdict: verdict_code, score: result[:score])
    log_biometric_attempt(
      user_id: user_id,
      outcome: result[:status],
      score: result[:score],
      coverage_ratio: result[:coverage_ratio],
      matched_pairs: result[:matched_pairs],
      timings: timings
    )
    
    # Log the result status
    $logger.info "Login attempt for User #{user_id}: #{result[:status]} (Score: #{result[:score]})"

    json_success(result)

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
  ensure_required_tables!
rescue PG::Error => e
  $logger.error "Schema readiness check failed: #{e.message}"
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

    json_success({ status: 'SUCCESS', message: 'Account created' })
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

    json_success({
      status: 'SUCCESS',
      token: token,
      user_id: user_id,
      username: username,
      expires_at: expires_at
    })
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

    json_success({
      status: 'SUCCESS',
      user_id: user_id,
      username: session['username'],
      biometric_pairs: profile_count
    })
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
    json_success({ status: 'SUCCESS', message: 'Logged out' })
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

    json_success({
      status: 'SUCCESS',
      token: new_token,
      user_id: session['user_id'].to_i,
      username: session['username'],
      expires_at: new_expires_at
    })
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

get '/admin/login' do
  erb :admin_login
end

post '/admin/login' do
  username = params['username'].to_s.strip
  password = params['password'].to_s

  if username == admin_username && verify_admin_password(password)
    session[:admin_user] = username
    log_audit_event(event_type: 'ADMIN_LOGIN', actor: username, metadata: { success: true })
    redirect '/admin'
  else
    log_audit_event(event_type: 'ADMIN_LOGIN', actor: username.empty? ? 'unknown' : username, metadata: { success: false })
    @error_message = 'Invalid admin credentials. Please check username/password and try again.'
    status 401
    erb :admin_login
  end
end

post '/admin/logout' do
  actor = session[:admin_user] || 'unknown'
  session.delete(:admin_user)
  log_audit_event(event_type: 'ADMIN_LOGOUT', actor: actor)
  redirect '/admin/login'
end

get '/admin' do
  require_dashboard_read!
  erb :admin_dashboard
end

get '/admin/api/overview' do
  content_type :json
  require_dashboard_read!

  service = DashboardService.new(db: DB, uptime_seconds: Time.now - APP_BOOT_TIME)
  json_success(service.overview(can_control: can_control_dashboard?, is_admin: admin_authenticated?))
end

get '/admin/api/feed' do
  content_type :json
  require_dashboard_read!

  limit = params['limit']&.to_i || 50
  limit = 200 if limit > 200
  limit = 1 if limit < 1

  service = DashboardService.new(db: DB, uptime_seconds: Time.now - APP_BOOT_TIME)
  json_success({ attempts: service.latest_attempts(limit: limit) })
end

post '/admin/api/attempt/:id/label' do
  content_type :json
  require_dashboard_control!

  attempt_id = params['id'].to_i
  return json_error('Invalid attempt id', 400, 'INVALID_ATTEMPT') if attempt_id <= 0

  payload_raw = request.body.read
  payload = payload_raw.nil? || payload_raw.strip.empty? ? {} : JSON.parse(payload_raw)
  label = normalize_attempt_label(payload['label'])
  return json_error('Label must be GENUINE, IMPOSTER, or UNLABELED', 400, 'INVALID_LABEL') if label == :invalid

  updated = DB.exec_params('UPDATE biometric_attempts SET label = $1 WHERE id = $2', [label, attempt_id]).cmd_tuples
  return json_error('Attempt not found', 404, 'ATTEMPT_NOT_FOUND') if updated == 0

  log_audit_event(
    event_type: 'LABEL_ATTEMPT',
    actor: session[:admin_user] || 'token-admin',
    metadata: { attempt_id: attempt_id, label: label }
  )

  json_success({ status: 'SUCCESS', attempt_id: attempt_id, label: label })
rescue JSON::ParserError
  json_error('Invalid JSON payload', 400, 'INVALID_JSON')
end

post '/admin/api/attempts/label-bulk' do
  content_type :json
  require_dashboard_control!

  payload_raw = request.body.read
  payload = payload_raw.nil? || payload_raw.strip.empty? ? {} : JSON.parse(payload_raw)
  label = normalize_attempt_label(payload['label'])
  return json_error('Label must be GENUINE, IMPOSTER, or UNLABELED', 400, 'INVALID_LABEL') if label == :invalid

  clauses = []
  params = []

  if payload.key?('user_id') && !payload['user_id'].to_s.strip.empty?
    user_id = payload['user_id'].to_i
    return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id <= 0
    params << user_id
    clauses << "user_id = $#{params.length}"
  end

  if payload.key?('outcome') && !payload['outcome'].to_s.strip.empty?
    params << payload['outcome'].to_s.strip.upcase
    clauses << "outcome = $#{params.length}"
  end

  if payload.key?('from_time') && !payload['from_time'].to_s.strip.empty?
    params << payload['from_time'].to_s
    clauses << "created_at >= $#{params.length}::timestamp"
  end

  if payload.key?('to_time') && !payload['to_time'].to_s.strip.empty?
    params << payload['to_time'].to_s
    clauses << "created_at <= $#{params.length}::timestamp"
  end

  return json_error('At least one filter is required for bulk labeling', 400, 'MISSING_FILTER') if clauses.empty?

  params << label
  label_param_idx = params.length
  where_sql = clauses.join(' AND ')

  updated = DB.exec_params(
    "UPDATE biometric_attempts
     SET label = $#{label_param_idx}
     WHERE #{where_sql}",
    params
  ).cmd_tuples

  log_audit_event(
    event_type: 'LABEL_ATTEMPT_BULK',
    actor: session[:admin_user] || 'token-admin',
    metadata: {
      label: label,
      filters: {
        user_id: payload['user_id'],
        outcome: payload['outcome'],
        from_time: payload['from_time'],
        to_time: payload['to_time']
      },
      updated: updated
    }
  )

  json_success({ status: 'SUCCESS', updated: updated, label: label })
rescue JSON::ParserError
  json_error('Invalid JSON payload', 400, 'INVALID_JSON')
end

get '/admin/api/user/:user_id' do
  content_type :json
  require_dashboard_read!

  user_id = params['user_id'].to_i
  return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id <= 0

  service = DashboardService.new(db: DB, uptime_seconds: Time.now - APP_BOOT_TIME)
  json_success(service.user_detail(user_id))
end

post '/admin/api/recalibrate/:user_id' do
  content_type :json
  require_dashboard_control!

  user_id = params['user_id'].to_i
  return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id <= 0

  thresholds = AuthService.calibrated_thresholds_for_user(user_id)
  log_audit_event(
    event_type: 'ADMIN_RECALIBRATE',
    actor: session[:admin_user] || 'token-admin',
    user_id: user_id,
    metadata: thresholds
  )

  json_success({ status: 'SUCCESS', user_id: user_id, thresholds: thresholds })
end

post '/admin/api/reset-user/:user_id' do
  content_type :json
  require_dashboard_control!

  user_id = params['user_id'].to_i
  return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id <= 0

  profile_deleted = DB.exec_params('DELETE FROM biometric_profiles WHERE user_id = $1', [user_id]).cmd_tuples
  history_deleted = DB.exec_params('DELETE FROM user_score_history WHERE user_id = $1', [user_id]).cmd_tuples
  threshold_deleted = DB.exec_params('DELETE FROM user_score_thresholds WHERE user_id = $1', [user_id]).cmd_tuples

  log_audit_event(
    event_type: 'RESET_USER',
    actor: session[:admin_user] || 'token-admin',
    user_id: user_id,
    metadata: {
      profile_deleted: profile_deleted,
      history_deleted: history_deleted,
      threshold_deleted: threshold_deleted
    }
  )

  json_success({
    status: 'SUCCESS',
    user_id: user_id,
    profile_deleted: profile_deleted,
    history_deleted: history_deleted,
    threshold_deleted: threshold_deleted
  })
end

post '/admin/api/export-dataset' do
  content_type :json
  require_dashboard_control!

  body_data = request.body.read
  payload = body_data.nil? || body_data.strip.empty? ? {} : JSON.parse(body_data)

  format = payload['format'].to_s.downcase
  format = 'json' unless ['json', 'csv'].include?(format)

  suffix = Time.now.utc.strftime('%Y%m%d_%H%M%S')
  extension = format == 'csv' ? 'csv' : 'json'
  output_path = File.expand_path("../exports/dataset_#{suffix}.#{extension}", __dir__)

  service = EvaluationService.new(db: DB)
  result = service.export_dataset(
    file_path: output_path,
    format: format,
    user_id: payload['user_id'],
    from_time: payload['from_time'],
    to_time: payload['to_time'],
    outcome: payload['outcome']
  )

  log_audit_event(
    event_type: 'EXPORT_DATASET',
    actor: session[:admin_user] || 'token-admin',
    metadata: result
  )

  json_success({ status: 'SUCCESS', export: result })
rescue JSON::ParserError
  json_error('Invalid JSON payload', 400, 'INVALID_JSON')
end

post '/admin/api/run-evaluation' do
  content_type :json
  require_dashboard_control!

  service = EvaluationService.new(db: DB)
  report = service.evaluate_and_write

  log_audit_event(
    event_type: 'RUN_EVALUATION',
    actor: session[:admin_user] || 'token-admin',
    metadata: report
  )

  json_success({ status: 'SUCCESS', evaluation: report })
end

post '/admin/api/cleanup-sessions' do
  content_type :json
  require_dashboard_control!

  deleted = DB.exec('DELETE FROM user_sessions WHERE expires_at <= NOW()').cmd_tuples
  log_audit_event(
    event_type: 'CLEANUP_SESSIONS',
    actor: session[:admin_user] || 'token-admin',
    metadata: { deleted: deleted }
  )

  json_success({ status: 'SUCCESS', deleted_sessions: deleted })
end