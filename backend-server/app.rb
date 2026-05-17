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
require 'rack/utils'
require 'redis'
require_relative 'lib/auth_service'
require_relative 'lib/dashboard_service'
require_relative 'lib/evaluation_service'
require_relative 'lib/advanced_biometric_analysis'

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

def required_env!(key, min_length: nil)
  value = ENV[key].to_s
  abort("Missing required environment variable: #{key}") if value.empty?
  if !min_length.nil? && value.length < min_length
    abort("Environment variable #{key} must be at least #{min_length} characters")
  end
  value
end

set :bind, '0.0.0.0'
set :port, 4567
use ApiVersionMiddleware

# Configure logging
$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO

AUTH_RATE_LIMIT_MAX = 30
AUTH_RATE_LIMIT_WINDOW_SECONDS = 60
AUTH_LOCKOUT_THRESHOLD = 5
AUTH_LOCKOUT_WINDOW_MINUTES = 15
APP_BOOT_TIME = Time.now
APP_ENV = ENV.fetch('APP_ENV', ENV.fetch('RACK_ENV', 'development'))
APP_REQUIRE_HTTPS = ENV['APP_REQUIRE_HTTPS'] == 'true'
ENABLE_ADVANCED_INTELLIGENCE = ENV.fetch('ENABLE_ADVANCED_INTELLIGENCE', 'true') == 'true'
APP_SESSION_SECRET = required_env!('APP_SESSION_SECRET', min_length: 32)
SESSION_TOKEN_PEPPER = required_env!('SESSION_TOKEN_PEPPER', min_length: 32)
APP_AUTH_PEPPER = required_env!('APP_AUTH_PEPPER', min_length: 16)
SESSION_DURATION_HOURS = ENV.fetch('SESSION_DURATION_HOURS', '4').to_i.clamp(1, 12)
TRUSTED_PROXY_IPS = ENV.fetch('TRUSTED_PROXY_IPS', '127.0.0.1,::1').split(',').map(&:strip)
BIOMETRIC_LOGIN_RATE_LIMIT_MAX = ENV.fetch('BIOMETRIC_LOGIN_RATE_LIMIT_MAX', '20').to_i
BIOMETRIC_TRAIN_RATE_LIMIT_MAX = ENV.fetch('BIOMETRIC_TRAIN_RATE_LIMIT_MAX', '15').to_i
ADMIN_API_RATE_LIMIT_MAX = ENV.fetch('ADMIN_API_RATE_LIMIT_MAX', '60').to_i
ADMIN_API_RATE_LIMIT_WINDOW_SECONDS = ENV.fetch('ADMIN_API_RATE_LIMIT_WINDOW_SECONDS', '60').to_i
APP_ALLOWED_ORIGINS = ENV.fetch('APP_ALLOWED_ORIGINS', '').split(',').map(&:strip).reject(&:empty?)
APP_ALLOWED_HOSTS = ENV.fetch('APP_ALLOWED_HOSTS', '').split(',').map(&:strip).reject(&:empty?)
TIMING_KEY_PAIR_REGEX = /\A[a-zA-Z0-9:_-]{1,16}\z/
TYPING_EVENT_TYPE_ALLOWLIST = %w[KEYDOWN KEYUP INPUT BACKSPACE DELETE PASTE CUT FOCUS BLUR SUBMIT COMPOSITIONSTART COMPOSITIONEND].freeze
REDIS_URL = ENV['REDIS_URL'].to_s.strip
ENABLE_ASYNC_ADMIN_JOBS = ENV.fetch('ENABLE_ASYNC_ADMIN_JOBS', 'true') == 'true'
REQUIRE_ADMIN_TOKEN_HASH = ENV.fetch('REQUIRE_ADMIN_TOKEN_HASH', APP_ENV == 'production' ? 'true' : 'false') == 'true'
DATA_RETENTION_DAYS = ENV.fetch('DATA_RETENTION_DAYS', '365').to_i.clamp(30, 3650)

set :protection, true
set :show_exceptions, APP_ENV == 'development'

set :sessions,
    key: 'biokey.session',
    httponly: true,
    secure: APP_REQUIRE_HTTPS,
    same_site: :lax,
    expire_after: SESSION_DURATION_HOURS * 3600,
    secret: APP_SESSION_SECRET

if APP_ENV == 'production' && !APP_REQUIRE_HTTPS
  abort('APP_REQUIRE_HTTPS=true is required in production')
end

if APP_ENV == 'production' && APP_ALLOWED_HOSTS.empty?
  abort('APP_ALLOWED_HOSTS must include expected public hostnames in production')
end

if REQUIRE_ADMIN_TOKEN_HASH && !ENV['ADMIN_TOKEN_HASH'].to_s.match?(/\A[0-9a-f]{64}\z/)
  abort('ADMIN_TOKEN_HASH must be a lowercase SHA-256 hex digest when REQUIRE_ADMIN_TOKEN_HASH=true')
end

RATE_LIMIT_MUTEX = Mutex.new
RATE_LIMIT_BUCKETS = {}
METRICS_MUTEX = Mutex.new
METRICS = {
  requests_total: 0,
  requests_by_route: Hash.new(0),
  responses_by_status: Hash.new(0),
  request_duration_ms_total: 0.0,
  request_duration_ms_max: 0.0,
  auth_failures_total: 0,
  rate_limit_hits_total: 0
}
REQUIRED_TABLES = %w[
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
].freeze

REDIS_CLIENT = begin
  if REDIS_URL.empty?
    nil
  else
    redis = Redis.new(url: REDIS_URL, connect_timeout: 1.5, read_timeout: 1.5, write_timeout: 1.5)
    redis.ping
    redis
  end
rescue => e
  warn "Redis unavailable, falling back to in-memory rate limiting: #{e.message}"
  nil
end

before do
  request.env['BIOKEY_REQUEST_STARTED_AT'] = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
  headers 'Permissions-Policy' => 'geolocation=(), microphone=(), camera=()'

  if !APP_ALLOWED_HOSTS.empty?
    incoming_host = request.host.to_s.downcase
    unless APP_ALLOWED_HOSTS.include?(incoming_host)
      content_type :json
      halt 400, json_error('Invalid Host header', 400, 'INVALID_HOST')
    end
  end

  origin = request.env['HTTP_ORIGIN'].to_s
  if !origin.empty? && APP_ALLOWED_ORIGINS.include?(origin)
    headers 'Access-Control-Allow-Origin' => origin
    headers 'Vary' => 'Origin'
    headers 'Access-Control-Allow-Methods' => 'GET,POST,OPTIONS'
    headers 'Access-Control-Allow-Headers' => 'Authorization,Content-Type,X-Admin-Token,X-Request-Id'
  end

  if request.secure? || request.env['HTTP_X_FORWARDED_PROTO'] == 'https'
    headers 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
  end

  if APP_REQUIRE_HTTPS
    secure = request.secure? || request.env['HTTP_X_FORWARDED_PROTO'] == 'https'
    unless secure
      content_type :json
      halt 426, json_error('HTTPS required for this environment', 426, 'HTTPS_REQUIRED')
    end
  end
end

after do
  started_at = request.env['BIOKEY_REQUEST_STARTED_AT']
  duration_ms = if started_at
                  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0
                else
                  0.0
                end

  route_key = request.path_info.to_s
  route_key = '/v1/login' if route_key.end_with?('/login')
  route_key = '/v1/train' if route_key.end_with?('/train')

  METRICS_MUTEX.synchronize do
    METRICS[:requests_total] += 1
    METRICS[:requests_by_route][route_key] += 1
    METRICS[:responses_by_status][response.status.to_s] += 1
    METRICS[:request_duration_ms_total] += duration_ms
    METRICS[:request_duration_ms_max] = [METRICS[:request_duration_ms_max], duration_ms].max
  end
end

# Load Database Configuration
begin
  db_config = if File.exist?('config/database.yml')
                loaded = if YAML.respond_to?(:safe_load_file)
                           YAML.safe_load_file('config/database.yml', permitted_classes: [], aliases: false)
                         else
                           YAML.safe_load(File.read('config/database.yml'), permitted_classes: [], aliases: false)
                         end
                loaded.is_a?(Hash) ? (loaded['development'] || {}) : {}
              else
                {}
              end
rescue => e
  $logger.warn "Could not load config/database.yml: #{e.message}"
  db_config = {}
end

DB_NAME = ENV['DB_NAME'] || db_config['database'] || 'biokey_db'
DB_USER = ENV['DB_USER'] || db_config['user'] || 'postgres'
DB_PASS = ENV['DB_PASSWORD'] || db_config['password']
DB_HOST = ENV['DB_HOST'] || db_config['host'] || 'localhost'

if APP_ENV == 'production' && DB_PASS.to_s.empty?
  abort('DB_PASSWORD is required in production')
end

class ResilientDb
  def initialize(dbname:, user:, password:, host:, logger:)
    @dbname = dbname
    @user = user
    @password = password
    @host = host
    @logger = logger
    @mutex = Mutex.new
    @conn = nil

    connect!
  end

  def exec(sql)
    with_retry { |conn| conn.exec(sql) }
  end

  def exec_params(sql, params)
    with_retry { |conn| conn.exec_params(sql, params) }
  end

  def transaction
    result = nil
    with_retry do |conn|
      if conn.respond_to?(:transaction)
        conn.transaction do |tx_conn|
          result = yield tx_conn
        end
      else
        conn.exec('BEGIN')
        begin
          result = yield conn
          conn.exec('COMMIT')
        rescue
          begin
            conn.exec('ROLLBACK')
          rescue
            nil
          end
          raise
        end
      end
    end
    result
  end

  def close
    @mutex.synchronize do
      begin
        @conn&.close
      rescue
        nil
      ensure
        @conn = nil
      end
    end
  end

  private

  def connect_locked!
    begin
      @conn&.close
    rescue
      nil
    end

    @conn = PG.connect(
      dbname: @dbname,
      user: @user,
      password: @password,
      host: @host
    )
  end

  def connect!
    @mutex.synchronize { connect_locked! }
  end

  def connection_alive?
    conn = @conn
    return false if conn.nil?

    begin
      return false if conn.respond_to?(:finished?) && conn.finished?
      return false if conn.respond_to?(:status) && conn.status != PG::CONNECTION_OK
    rescue
      return false
    end

    true
  end

  def with_connection_locked
    connect_locked! unless connection_alive?
    @conn
  end

  def recoverable_pg_error?(error)
    msg = error.message.to_s
    return true if msg.include?('no connection to the server')
    return true if msg.include?('connection is closed')
    return true if msg.include?('server closed the connection unexpectedly')
    return true if msg.include?('terminating connection due to administrator command')
    false
  end

  def with_retry(max_attempts: 2)
    attempt = 0

    begin
      attempt += 1
      @mutex.synchronize do
        conn = with_connection_locked
        return yield conn
      end
    rescue PG::Error => e
      raise if attempt >= max_attempts
      raise unless recoverable_pg_error?(e)

      @logger.warn "DB connection lost; reconnecting and retrying (attempt #{attempt + 1}/#{max_attempts}): #{e.message}"
      connect!
      retry
    end
  end
end

begin
  DB = ResilientDb.new(
    dbname: DB_NAME,
    user: DB_USER,
    password: DB_PASS,
    host: DB_HOST,
    logger: $logger
  )
  $logger.info "Connected to database #{DB_NAME} at #{DB_HOST}"
rescue PG::Error => e
  $logger.error "Unable to connect to database: #{e.message}"
  exit(1)
end

def open_fresh_db_connection
  PG.connect(
    dbname:   DB_NAME,
    user:     DB_USER,
    password: DB_PASS,
    host:     DB_HOST
  )
end

def with_dashboard_service
  primary_service = DashboardService.new(db: DB, uptime_seconds: Time.now - APP_BOOT_TIME)
  return yield primary_service
rescue PG::Error => e
  $logger.warn "Dashboard query failed on primary DB connection, retrying with fresh connection: #{e.message}"

  fresh_db = nil
  begin
    fresh_db = open_fresh_db_connection
    fallback_service = DashboardService.new(db: fresh_db, uptime_seconds: Time.now - APP_BOOT_TIME)
    yield fallback_service
  rescue PG::Error => inner
    $logger.error "Dashboard query failed after retry: #{inner.message}"
    json_error('Dashboard data temporarily unavailable. Please refresh in a few seconds.', 503, 'DB_UNAVAILABLE')
  ensure
    fresh_db&.close
  end
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
  ip = request.env['REMOTE_ADDR'].to_s
  return true if ['127.0.0.1', '::1', 'localhost'].include?(ip)

  return false unless trusted_proxy_request?

  forwarded = request.env['HTTP_X_FORWARDED_FOR'].to_s
  forwarded.split(',').map(&:strip).any? { |part| ['127.0.0.1', '::1', 'localhost'].include?(part) }
end

def trusted_proxy_request?
  return false unless ENV['TRUST_PROXY'] == '1'

  remote_ip = request.env['REMOTE_ADDR'].to_s
  TRUSTED_PROXY_IPS.include?(remote_ip)
end

def ensure_required_tables!
  missing = REQUIRED_TABLES.select do |table_name|
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
  request.env['HTTP_X_ADMIN_TOKEN'].to_s
end

def admin_authenticated?
  session[:admin_user] == admin_username
end

def secure_compare?(a, b)
  return false if a.nil? || b.nil?
  return false unless a.bytesize == b.bytesize

  Rack::Utils.secure_compare(a, b)
end

def admin_token_valid?
  token_hash = ENV['ADMIN_TOKEN_HASH'].to_s
  return false if token_hash.empty?

  presented_hash = Digest::SHA256.hexdigest(admin_token)
  secure_compare?(presented_hash, token_hash)
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

def mark_auth_failure!
  METRICS_MUTEX.synchronize { METRICS[:auth_failures_total] += 1 }
end

def metrics_snapshot
  METRICS_MUTEX.synchronize do
    {
      requests_total: METRICS[:requests_total],
      requests_by_route: METRICS[:requests_by_route].dup,
      responses_by_status: METRICS[:responses_by_status].dup,
      request_duration_ms_total: METRICS[:request_duration_ms_total],
      request_duration_ms_max: METRICS[:request_duration_ms_max],
      auth_failures_total: METRICS[:auth_failures_total],
      rate_limit_hits_total: METRICS[:rate_limit_hits_total]
    }
  end
end

def schema_readiness
  missing = REQUIRED_TABLES.select do |table_name|
    DB.exec_params('SELECT to_regclass($1) AS table_ref', [table_name])[0]['table_ref'].nil?
  end

  {
    ready: missing.empty?,
    missing_tables: missing
  }
rescue PG::Error => e
  {
    ready: false,
    missing_tables: REQUIRED_TABLES,
    error: e.message
  }
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

def same_origin_request?
  base = "#{request.scheme}://#{request.host_with_port}"
  origin = request.env['HTTP_ORIGIN'].to_s.strip
  return origin == base unless origin.empty?

  referer = request.env['HTTP_REFERER'].to_s.strip
  return referer.start_with?(base) unless referer.empty?

  false
end

def require_same_origin_for_cookie_session!(api: false)
  return unless admin_authenticated?
  return if admin_token_valid?
  return if same_origin_request?

  if api
    content_type :json
    halt 403, json_error('Potential CSRF request blocked', 403, 'CSRF_BLOCKED')
  else
    halt 403, 'Forbidden'
  end
end

def sanitize_metadata(value, depth = 0)
  return {} if depth > 4

  case value
  when Hash
    value.each_with_object({}) do |(k, v), out|
      key = k.to_s[0, 64]
      out[key] = sanitize_metadata(v, depth + 1)
    end
  when Array
    value.first(50).map { |entry| sanitize_metadata(entry, depth + 1) }
  when String
    value[0, 256]
  when Numeric, TrueClass, FalseClass, NilClass
    value
  else
    value.to_s[0, 128]
  end
end

def enqueue_admin_job(job_type, payload = {})
  job_id = SecureRandom.uuid
  created_at = Time.now.utc.iso8601

  if REDIS_CLIENT && ENABLE_ASYNC_ADMIN_JOBS
    REDIS_CLIENT.hset("biokey:jobs:#{job_id}", {
      'job_type' => job_type,
      'status' => 'queued',
      'payload' => JSON.generate(sanitize_metadata(payload)),
      'created_at' => created_at
    })
    REDIS_CLIENT.expire("biokey:jobs:#{job_id}", 86400)
    REDIS_CLIENT.lpush('biokey:jobs:queue', JSON.generate({ job_id: job_id, job_type: job_type, payload: sanitize_metadata(payload), created_at: created_at }))
  else
    DB.exec_params(
      'INSERT INTO async_jobs (id, job_type, status, payload, created_at) VALUES ($1, $2, $3, $4::jsonb, NOW()) ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status, payload = EXCLUDED.payload',
      [job_id, job_type.to_s, 'queued', sanitize_metadata(payload).to_json]
    )
  end

  job_id
end

def record_async_job_status(job_id, status, payload = {})
  if REDIS_CLIENT && ENABLE_ASYNC_ADMIN_JOBS
    REDIS_CLIENT.hset("biokey:jobs:#{job_id}", {
      'status' => status,
      'result' => JSON.generate(sanitize_metadata(payload)),
      'updated_at' => Time.now.utc.iso8601
    })
  else
    DB.exec_params(
      'UPDATE async_jobs SET status = $2, result = $3::jsonb, updated_at = NOW() WHERE id = $1',
      [job_id, status.to_s, sanitize_metadata(payload).to_json]
    )
  end
end

def fetch_async_job(job_id)
  if REDIS_CLIENT && ENABLE_ASYNC_ADMIN_JOBS
    result = REDIS_CLIENT.hgetall("biokey:jobs:#{job_id}")
    return nil if result.nil? || result.empty?

    {
      'id' => job_id,
      'job_type' => result['job_type'],
      'status' => result['status'],
      'payload' => begin
        raw = result['payload']
        raw.nil? || raw.empty? ? {} : JSON.parse(raw)
      rescue
        {}
      end,
      'result' => begin
        raw = result['result']
        raw.nil? || raw.empty? ? nil : JSON.parse(raw)
      rescue
        nil
      end,
      'created_at' => result['created_at'],
      'updated_at' => result['updated_at']
    }
  else
    row = DB.exec_params('SELECT id, job_type, status, payload, result, created_at, updated_at FROM async_jobs WHERE id = $1 LIMIT 1', [job_id])[0]
    return nil if row.nil?

    row['payload'] = begin
      raw = row['payload']
      raw.nil? || raw.empty? ? {} : JSON.parse(raw)
    rescue
      {}
    end

    row['result'] = begin
      raw = row['result']
      raw.nil? || raw.empty? ? nil : JSON.parse(raw)
    rescue
      nil
    end

    row
  end
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
  normalized_event_type = event_type.to_s.strip.upcase.gsub(/[^A-Z0-9_]/, '')[0, 64]
  normalized_event_type = 'UNKNOWN_EVENT' if normalized_event_type.empty?

  DB.exec_params(
    'INSERT INTO audit_events (event_type, actor, user_id, ip_address, request_id, metadata) VALUES ($1, $2, $3, $4, $5, $6::jsonb)',
    [
      normalized_event_type,
      actor.to_s[0, 64],
      user_id,
      client_ip,
      current_request_id,
      sanitize_metadata(metadata).to_json
    ]
  )
rescue PG::Error => e
  $logger.warn "Failed to write audit event #{event_type}: #{e.message}"
end

def log_biometric_attempt(user_id:, outcome:, score:, coverage_ratio:, matched_pairs:, timings: nil)
  safe_coverage = coverage_ratio.to_f
  safe_coverage = nil unless safe_coverage.finite? && safe_coverage >= 0.0 && safe_coverage <= 1.0

  safe_pairs = matched_pairs.to_i
  safe_pairs = nil if safe_pairs < 0

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
      safe_coverage,
      safe_pairs,
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
    return false unless normalized[:pair].match?(TIMING_KEY_PAIR_REGEX)
    return false if normalized[:dwell] < 10 || normalized[:flight] < 5
    return false if normalized[:dwell] > 5000 || normalized[:flight] > 5000
  end

  true
end

def parse_positive_int(value)
  return nil unless value.to_s.match?(/\A\d+\z/)

  parsed = value.to_i
  parsed > 0 ? parsed : nil
end

def require_rate_limit!(scope:, key:, limit:, window_seconds:, message:, code:)
  return unless rate_limited?(scope, key, limit: limit, window_seconds: window_seconds)

  METRICS_MUTEX.synchronize { METRICS[:rate_limit_hits_total] += 1 }

  halt 429, json_error(message, 429, code)
end

def redis_rate_limit_key(scope, key)
  "biokey:rate_limit:#{scope}:#{key}"
end

def redis_rate_limited?(scope, key, limit:, window_seconds:)
  return nil if REDIS_CLIENT.nil?

  now = Time.now.to_i
  redis_key = redis_rate_limit_key(scope, key)

  REDIS_CLIENT.multi do |multi|
    multi.zremrangebyscore(redis_key, 0, now - window_seconds)
    multi.zcard(redis_key)
    multi.zadd(redis_key, now, "#{now}:#{SecureRandom.hex(4)}")
    multi.expire(redis_key, window_seconds + 5)
  end.then do |results|
    current_count = results[1].to_i
    current_count >= limit
  end
rescue => e
  $logger.warn "Redis rate limit failed for #{scope}: #{e.message}"
  nil
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
      pair: pair.to_s.strip,
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

def normalized_timing_series(timings)
  return [] unless timings.is_a?(Array)

  timings.each_with_index.map do |t, idx|
    sample = normalize_timing_sample(t, idx)
    next nil if sample.nil?

    {
      'pair' => sample[:pair],
      'dwell' => sample[:dwell],
      'flight' => sample[:flight]
    }
  end.compact
end

def payload_hash_verified?(raw_body)
  expected_hash = request.env['HTTP_X_PAYLOAD_HASH'].to_s.strip
  require_hash = ENV['REQUIRE_PAYLOAD_HASH'] == 'true'

  return true if expected_hash.empty? && !require_hash
  return false if expected_hash.empty?

  actual_hash = Digest::SHA256.hexdigest(raw_body.to_s)
  secure_compare?(actual_hash, expected_hash)
end

def fetch_profile_rows(user_id)
  result = DB.exec_params(
    "SELECT key_pair, avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count
     FROM biometric_profiles
     WHERE user_id = $1
     LIMIT 500",
    [user_id]
  )

  result.map do |row|
    {
      'key_pair' => row['key_pair'],
      'avg_dwell_time' => row['avg_dwell_time'].to_f,
      'avg_flight_time' => row['avg_flight_time'].to_f,
      'std_dev_dwell' => row['std_dev_dwell'].to_f,
      'std_dev_flight' => row['std_dev_flight'].to_f,
      'sample_count' => row['sample_count'].to_i
    }
  end
rescue PG::Error => e
  $logger.warn "Unable to load profile rows for intelligence: #{e.message}"
  []
end

def risk_level_for_signals(entropy_norm:, consistency_score:, spoofability_risk:, verification_status:)
  score = 0
  score += 2 if entropy_norm > 0.85
  score += 1 if entropy_norm > 0.70
  score += 2 if consistency_score < 0.35
  score += 1 if consistency_score < 0.55
  score += 2 if spoofability_risk == 'high'
  score += 1 if spoofability_risk == 'medium'
  score += 1 if verification_status == 'CHALLENGE'
  score += 2 if verification_status == 'DENIED'

  return 'high' if score >= 5
  return 'medium' if score >= 3

  'low'
end

def build_biometric_intelligence(user_id, timings, verification_result = nil)
  normalized = normalized_timing_series(timings)
  return { available: false, reason: 'no_valid_timing_samples' } if normalized.empty?

  profile_rows = fetch_profile_rows(user_id)
  entropy = AdvancedBiometricAnalysis.keystroke_entropy(normalized)
  consistency = AdvancedBiometricAnalysis.temporal_consistency_analysis(normalized)
  uniqueness = if profile_rows.empty?
                 {
                   uniqueness_score: nil,
                   spoofability_risk: 'unknown'
                 }
               else
                 AdvancedBiometricAnalysis.pattern_uniqueness_score(profile_rows)
               end

  verification_status = verification_result&.dig(:status)
  risk_level = risk_level_for_signals(
    entropy_norm: entropy[:entropy_normalized].to_f,
    consistency_score: consistency[:consistency_score].to_f,
    spoofability_risk: uniqueness[:spoofability_risk].to_s,
    verification_status: verification_status.to_s
  )

  response = {
    available: true,
    risk_level: risk_level,
    recommended_action: (risk_level == 'high' ? 'step_up_auth' : (risk_level == 'medium' ? 'challenge_or_monitor' : 'allow')),
    entropy: {
      total: entropy[:total_entropy].to_f.round(4),
      normalized: entropy[:entropy_normalized].to_f.round(4)
    },
    temporal_consistency: {
      score: consistency[:consistency_score].to_f.round(4),
      avg_speed_change: consistency[:avg_speed_change].to_f.round(4)
    },
    profile_uniqueness: {
      score: uniqueness[:uniqueness_score].nil? ? nil : uniqueness[:uniqueness_score].to_f.round(4),
      spoofability_risk: uniqueness[:spoofability_risk]
    },
    sample_size: normalized.length
  }

  if verification_result.is_a?(Hash) && verification_result[:status]
    thresholds = {
      success: verification_result[:success_threshold].to_f,
      challenge: verification_result[:challenge_threshold].to_f
    }

    if thresholds[:success] > 0 && thresholds[:challenge] > 0 && verification_result[:score]
      response[:decision_explanation] = AdvancedBiometricAnalysis.explain_decision(
        verification_result[:status].to_s,
        verification_result[:score].to_f,
        thresholds
      )
    end
  end

  response
rescue => e
  $logger.warn "Biometric intelligence failed for user #{user_id}: #{e.message}"
  { available: false, reason: 'analysis_failed' }
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
    session = require_authenticated_api_session!
    user_id = session['user_id'].to_i

    require_rate_limit!(
      scope: 'biometric-train-ip',
      key: client_ip,
      limit: BIOMETRIC_TRAIN_RATE_LIMIT_MAX,
      window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS,
      message: 'Too many biometric training attempts. Try again shortly.',
      code: 'BIOMETRIC_TRAIN_RATE_LIMIT'
    )
    require_rate_limit!(
      scope: 'biometric-train-user',
      key: user_id,
      limit: BIOMETRIC_TRAIN_RATE_LIMIT_MAX,
      window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS,
      message: 'Too many biometric training attempts. Try again shortly.',
      code: 'BIOMETRIC_TRAIN_RATE_LIMIT'
    )

    raw_body = request.body.read
    return json_error('Invalid payload hash', 400, 'PAYLOAD_HASH_MISMATCH') unless payload_hash_verified?(raw_body)

    data = JSON.parse(raw_body)
    payload_user_id = parse_positive_int(data['user_id'])
    timings = data['timings']

    if !payload_user_id.nil? && payload_user_id != user_id
      return json_error('Authenticated user does not match payload user_id', 403, 'USER_ID_MISMATCH')
    end

    if !valid_timing_payload?(timings)
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
    session = require_authenticated_api_session!
    user_id = session['user_id'].to_i

    require_rate_limit!(
      scope: 'biometric-login-ip',
      key: client_ip,
      limit: BIOMETRIC_LOGIN_RATE_LIMIT_MAX,
      window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS,
      message: 'Too many biometric login attempts. Try again shortly.',
      code: 'BIOMETRIC_LOGIN_RATE_LIMIT'
    )
    require_rate_limit!(
      scope: 'biometric-login-user',
      key: user_id,
      limit: BIOMETRIC_LOGIN_RATE_LIMIT_MAX,
      window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS,
      message: 'Too many biometric login attempts. Try again shortly.',
      code: 'BIOMETRIC_LOGIN_RATE_LIMIT'
    )

    raw_body = request.body.read
    return json_error('Invalid payload hash', 400, 'PAYLOAD_HASH_MISMATCH') unless payload_hash_verified?(raw_body)

    data = JSON.parse(raw_body)
    payload_user_id = parse_positive_int(data['user_id'])
    timings = data['timings']

    if !payload_user_id.nil? && payload_user_id != user_id
      return json_error('Authenticated user does not match payload user_id', 403, 'USER_ID_MISMATCH')
    end

    if !valid_timing_payload?(timings)
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

    if ENABLE_ADVANCED_INTELLIGENCE
      intelligence = build_biometric_intelligence(user_id, timings, result)
      result[:intelligence] = intelligence

      if result[:status] == 'SUCCESS' && intelligence[:risk_level] == 'high'
        result[:status] = 'CHALLENGE'
        result[:policy_override] = 'HIGH_RISK_SIGNALS'
      end
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
  BCrypt::Password.create("#{APP_AUTH_PEPPER}:#{password}").to_s
end

def bcrypt_hash?(value)
  value.is_a?(String) && value.start_with?('$2a$', '$2b$', '$2y$')
end

def password_matches?(password, stored_hash)
  return false if stored_hash.nil? || stored_hash.empty?
  return false unless bcrypt_hash?(stored_hash)

  BCrypt::Password.new(stored_hash) == "#{APP_AUTH_PEPPER}:#{password}"
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
    keep_digest = session_token_digest(except_token)
    DB.exec_params(
      'DELETE FROM user_sessions WHERE user_id = $1 AND session_token <> $2',
      [user_id, keep_digest]
    )
  end
end

def generate_session_token
  SecureRandom.hex(32)
end

def session_token_digest(token)
  return nil if token.nil? || token.empty?

  Digest::SHA256.hexdigest("#{SESSION_TOKEN_PEPPER}:#{token}")
end

def session_token_candidates(token)
  digest = session_token_digest(token)
  digest.nil? ? [] : [digest]
end

def bearer_token
  auth_header = request.env['HTTP_AUTHORIZATION']
  return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

  auth_header.split(' ', 2).last
end

def active_session_for(token)
  return nil if token.nil? || token.empty?

  token_digest = session_token_digest(token)
  return nil if token_digest.nil?

  result = DB.exec_params(
    "SELECT s.user_id, u.username
     FROM user_sessions s
     JOIN users u ON u.id = s.user_id
     WHERE s.session_token = $1 AND s.expires_at > NOW()
     LIMIT 1",
    [token_digest]
  )

  return nil if result.ntuples == 0

  result[0]
end

def user_id_for_username(username)
  return nil if username.nil? || username.strip.empty?

  result = DB.exec_params('SELECT id FROM users WHERE username = $1 LIMIT 1', [username.strip])
  return nil if result.ntuples == 0

  result[0]['id']&.to_i
rescue PG::Error
  nil
rescue
  nil
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
    raw_body = nil
    begin
      raw_body = request.body.read
      request.body.rewind
    rescue
      raw_body = nil
    end

    if rate_limited?('auth-login-ip', ip_address, limit: AUTH_RATE_LIMIT_MAX, window_seconds: AUTH_RATE_LIMIT_WINDOW_SECONDS)
      attempted_username = nil
      begin
        attempted_username = JSON.parse(raw_body.to_s)['username']&.strip
      rescue
        attempted_username = nil
      end

      log_access_event(user_id: user_id_for_username(attempted_username), verdict: 'AUTH_RATE', score: nil)
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
      log_access_event(user_id: user_id_for_username(username), verdict: 'AUTH_LOCK', score: nil)
      return json_error('Account temporarily locked due to repeated failures', 423)
    end

    result = DB.exec_params(
      'SELECT id, password_hash FROM users WHERE username = $1 LIMIT 1',
      [username]
    )

    if result.ntuples == 0 || !password_matches?(password, result[0]['password_hash'])
      failing_user_id = result.ntuples > 0 ? result[0]['id'].to_i : nil
      record_login_attempt(username, ip_address, false)
      log_access_event(user_id: failing_user_id, verdict: 'AUTH_FAIL', score: nil)
      mark_auth_failure!
      return json_error('Invalid credentials', 401)
    end

    user_id = result[0]['id'].to_i
    stored_hash = result[0]['password_hash']

    unless bcrypt_hash?(stored_hash)
      return json_error('Password reset required before login', 403, 'PASSWORD_UPGRADE_REQUIRED')
    end

    cleanup_expired_sessions
    revoke_user_sessions(user_id)
    record_login_attempt(username, ip_address, true)
    clear_login_failures(username, ip_address)

    token = generate_session_token
    expires_at = (Time.now + SESSION_DURATION_HOURS * 60 * 60).utc

    DB.exec_params(
      'INSERT INTO user_sessions (user_id, session_token, expires_at) VALUES ($1, $2, $3)',
      [user_id, session_token_digest(token), expires_at]
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

post '/auth/intelligence' do
  content_type :json
  begin
    session = active_session_for(bearer_token)
    if session.nil?
      mark_auth_failure!
      return json_error('Unauthorized', 401)
    end

    data = JSON.parse(request.body.read)
    timings = data['timings']
    unless valid_timing_payload?(timings)
      return json_error('Missing or invalid timings payload', 400, 'INVALID_TIMINGS')
    end

    user_id = session['user_id'].to_i
    intelligence = build_biometric_intelligence(user_id, timings)
    log_audit_event(event_type: 'auth_intelligence', actor: 'user', user_id: user_id, metadata: { available: intelligence[:available] })

    json_success({
      status: 'SUCCESS',
      user_id: user_id,
      intelligence: intelligence
    })
  rescue JSON::ParserError
    json_error('Invalid JSON format', 400)
  rescue PG::Error => e
    $logger.error "Database error in /auth/intelligence: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/intelligence: #{e.message}"
    json_error('Internal Server Error')
  end
end

get '/auth/profile' do
  content_type :json
  begin
    session = active_session_for(bearer_token)
    if session.nil?
      mark_auth_failure!
      return json_error('Unauthorized', 401)
    end

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

get '/auth/export-data' do
  content_type :json
  begin
    session = active_session_for(bearer_token)
    if session.nil?
      mark_auth_failure!
      return json_error('Unauthorized', 401)
    end

    user_id = session['user_id'].to_i

    profile_rows = DB.exec_params(
      'SELECT key_pair, avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count FROM biometric_profiles WHERE user_id = $1 ORDER BY key_pair LIMIT 500',
      [user_id]
    ).map(&:to_h)

    score_rows = DB.exec_params(
      'SELECT score, outcome, coverage_ratio, matched_pairs, created_at FROM user_score_history WHERE user_id = $1 ORDER BY created_at DESC LIMIT 500',
      [user_id]
    ).map(&:to_h)

    attempt_rows = DB.exec_params(
      'SELECT outcome, score, coverage_ratio, matched_pairs, created_at FROM biometric_attempts WHERE user_id = $1 ORDER BY created_at DESC LIMIT 500',
      [user_id]
    ).map(&:to_h)

    consent_events = DB.exec_params(
      "SELECT event_type, metadata, created_at FROM audit_events WHERE user_id = $1 AND event_type = 'CONSENT_BIOMETRIC' ORDER BY created_at DESC LIMIT 50",
      [user_id]
    ).map(&:to_h)

    log_audit_event(event_type: 'USER_EXPORT_DATA', actor: 'user', user_id: user_id, metadata: { rows: { profiles: profile_rows.length, scores: score_rows.length, attempts: attempt_rows.length } })

    json_success({
      status: 'SUCCESS',
      user: {
        id: user_id,
        username: session['username']
      },
      export_generated_at: Time.now.utc.iso8601,
      biometric_profiles: profile_rows,
      score_history: score_rows,
      biometric_attempts: attempt_rows,
      consent_events: consent_events
    })
  rescue PG::Error => e
    $logger.error "Database error in /auth/export-data: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/export-data: #{e.message}"
    json_error('Internal Server Error')
  end
end

post '/auth/consent' do
  content_type :json
  begin
    session = active_session_for(bearer_token)
    if session.nil?
      mark_auth_failure!
      return json_error('Unauthorized', 401)
    end

    payload = JSON.parse(request.body.read)
    consent = payload['consent_biometric']
    return json_error('consent_biometric must be boolean', 400, 'INVALID_CONSENT') unless consent == true || consent == false

    log_audit_event(
      event_type: 'CONSENT_BIOMETRIC',
      actor: 'user',
      user_id: session['user_id'].to_i,
      metadata: {
        consent_biometric: consent,
        policy_version: payload['policy_version'].to_s.strip[0, 64],
        source: payload['source'].to_s.strip[0, 64],
        accepted_at: Time.now.utc.iso8601
      }
    )

    json_success({ status: 'SUCCESS', consent_biometric: consent })
  rescue JSON::ParserError
    json_error('Invalid JSON format', 400)
  rescue => e
    $logger.error "Unknown error in /auth/consent: #{e.message}"
    json_error('Internal Server Error')
  end
end

post '/auth/delete-account' do
  content_type :json
  begin
    session = active_session_for(bearer_token)
    return json_error('Unauthorized', 401) if session.nil?

    user_id = session['user_id'].to_i

    DB.transaction do |tx|
      tx.exec_params('DELETE FROM biometric_profiles WHERE user_id = $1', [user_id])
      tx.exec_params('DELETE FROM user_score_history WHERE user_id = $1', [user_id])
      tx.exec_params('DELETE FROM user_score_thresholds WHERE user_id = $1', [user_id])
      tx.exec_params('DELETE FROM biometric_attempts WHERE user_id = $1', [user_id])
      tx.exec_params('DELETE FROM access_logs WHERE user_id = $1', [user_id])
      tx.exec_params('DELETE FROM user_sessions WHERE user_id = $1', [user_id])
      tx.exec_params('DELETE FROM users WHERE id = $1', [user_id])
    end

    log_audit_event(event_type: 'USER_DELETE_ACCOUNT', actor: 'user', user_id: user_id)
    json_success({ status: 'SUCCESS', message: 'Account and biometric data deleted' })
  rescue PG::Error => e
    $logger.error "Database error in /auth/delete-account: #{e.message}"
    json_error('Database error')
  rescue => e
    $logger.error "Unknown error in /auth/delete-account: #{e.message}"
    json_error('Internal Server Error')
  end
end

post '/auth/logout' do
  content_type :json
  begin
    token = bearer_token
    if token.nil?
      log_access_event(user_id: nil, verdict: 'LOG_FAIL', score: nil)
      mark_auth_failure!
      return json_error('Missing authorization token', 401)
    end

    session = active_session_for(token)
    token_digest = session_token_digest(token)
    DB.exec_params(
      'DELETE FROM user_sessions WHERE session_token = $1',
      [token_digest]
    )
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
      mark_auth_failure!
      return json_error('Missing authorization token', 401)
    end

    session = active_session_for(token)
    if session.nil?
      log_access_event(user_id: nil, verdict: 'REF_FAIL', score: nil)
      mark_auth_failure!
      return json_error('Unauthorized', 401)
    end

    cleanup_expired_sessions
    revoke_user_sessions(session['user_id'].to_i, token)

    new_token = generate_session_token
    new_expires_at = (Time.now + SESSION_DURATION_HOURS * 60 * 60).utc

    old_digest = session_token_digest(token)
    updated = DB.exec_params(
      'UPDATE user_sessions SET session_token = $1, expires_at = $2 WHERE session_token = $3',
      [session_token_digest(new_token), new_expires_at, old_digest]
    )

    if updated.cmd_tuples == 0
      log_access_event(user_id: nil, verdict: 'REF_FAIL', score: nil)
      mark_auth_failure!
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

def authenticated_api_session
  token = bearer_token
  return nil if token.nil? || token.empty?

  active_session_for(token)
rescue
  nil
end

def require_authenticated_api_session!
  session = authenticated_api_session
  if session.nil?
    mark_auth_failure!
    halt 401, json_error('Unauthorized', 401, 'UNAUTHORIZED')
  end
  session
end

get '/prototype' do
  redirect '/prototype/login'
end

get '/prototype/login' do
  erb :prototype_login
end

get '/prototype/feed' do
  erb :prototype_feed
end

get '/prototype/api/profile' do
  content_type :json
  session = require_authenticated_api_session!

  json_success({
    status: 'SUCCESS',
    user_id: session['user_id'].to_i,
    username: session['username']
  })
end

post '/prototype/api/typing-events' do
  content_type :json
  session = require_authenticated_api_session!

  payload = JSON.parse(request.body.read)
  context = payload['context'].to_s.strip
  field_name = payload['field_name'].to_s.strip
  client_session_id = payload['client_session_id'].to_s.strip
  events = payload['events']

  return json_error('context is required', 400, 'INVALID_CONTEXT') if context.empty? || context.length > 64
  return json_error('field_name is required', 400, 'INVALID_FIELD') if field_name.empty? || field_name.length > 64
  return json_error('client_session_id is required', 400, 'INVALID_SESSION') if client_session_id.empty? || client_session_id.length > 64
  return json_error('events must be a non-empty array', 400, 'INVALID_EVENTS') unless events.is_a?(Array) && !events.empty?
  return json_error('events exceeds max batch size (500)', 400, 'INVALID_EVENTS') if events.length > 500

  inserted = 0
  DB.transaction do |tx|
    events.each do |event|
      event_type = event['event_type'].to_s.strip.upcase
      key_value = event['key_value'].to_s[0, 64]
      key_code = event['key_code']
      dwell_ms = event['dwell_ms']
      flight_ms = event['flight_ms']
      typed_length = event['typed_length']
      cursor_pos = event['cursor_pos']
      client_ts_ms = event['client_ts_ms']

      next unless TYPING_EVENT_TYPE_ALLOWLIST.include?(event_type)

      tx.exec_params(
        "INSERT INTO typing_capture_events (
           user_id, context, field_name, client_session_id, event_type,
           key_value, key_code, dwell_ms, flight_ms, typed_length,
           cursor_pos, client_ts_ms, ip_address, request_id, metadata
         ) VALUES (
           $1, $2, $3, $4, $5,
           $6, $7, $8, $9, $10,
           $11, $12, $13, $14, $15::jsonb
         )",
        [
          session['user_id'].to_i,
          context,
          field_name,
          client_session_id,
          event_type,
          key_value,
          key_code,
          dwell_ms,
          flight_ms,
          typed_length,
          cursor_pos,
          client_ts_ms,
          client_ip,
          current_request_id,
          sanitize_metadata(event['metadata'].is_a?(Hash) ? event['metadata'] : {}).to_json
        ]
      )

      inserted += 1
    end
  end

  json_success({ status: 'SUCCESS', inserted: inserted })
rescue JSON::ParserError
  json_error('Invalid JSON format', 400, 'INVALID_JSON')
rescue PG::UndefinedTable
  json_error('typing_capture_events table missing. Run migrations.', 503, 'TYPING_TABLE_MISSING')
rescue PG::Error => e
  $logger.error "Database error in /prototype/api/typing-events: #{e.message}"
  json_error('Database error')
rescue => e
  $logger.error "Unknown error in /prototype/api/typing-events: #{e.message}"
  json_error('Internal Server Error')
end

def client_ip
  forwarded = request.env['HTTP_X_FORWARDED_FOR']
  if trusted_proxy_request? && !forwarded.nil? && !forwarded.strip.empty?
    return forwarded.split(',').first.strip
  end

  remote_addr = request.env['REMOTE_ADDR'].to_s
  return remote_addr unless remote_addr.empty?

  request.ip.to_s
end

def rate_limited?(scope, key, limit:, window_seconds:)
  redis_result = redis_rate_limited?(scope, key, limit: limit, window_seconds: window_seconds)
  return redis_result unless redis_result.nil?

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
  begin
    DB.exec_params(
      'INSERT INTO access_logs (user_id, distance_score, verdict, ip_address, request_id) VALUES ($1, $2, $3, $4, $5)',
      [user_id, score, verdict.to_s[0, 10], client_ip, current_request_id]
    )
  rescue PG::UndefinedColumn
    DB.exec_params(
      'INSERT INTO access_logs (user_id, distance_score, verdict) VALUES ($1, $2, $3)',
      [user_id, score, verdict.to_s[0, 10]]
    )
  end
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
  require_same_origin_for_cookie_session!
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

  with_dashboard_service do |service|
    json_success(service.overview(can_control: can_control_dashboard?, is_admin: admin_authenticated?))
  end
end

get '/admin/api/feed' do
  content_type :json
  require_dashboard_read!

  limit = params['limit']&.to_i || 50
  limit = 50 if limit > 50
  limit = 1 if limit < 1

  with_dashboard_service do |service|
    json_success({ attempts: service.latest_attempts(limit: limit) })
  end
end

get '/admin/api/live-feed' do
  content_type :json
  require_dashboard_read!

  limit = params['limit']&.to_i || 50
  limit = 50 if limit > 50
  limit = 1 if limit < 1

  with_dashboard_service do |service|
    json_success({ events: service.latest_live_events(limit: limit) })
  end
end

get '/admin/api/auth-feed' do
  content_type :json
  require_dashboard_read!

  limit = params['limit']&.to_i || 50
  limit = 50 if limit > 50
  limit = 1 if limit < 1

  with_dashboard_service do |service|
    json_success({ events: service.latest_auth_events(limit: limit) })
  end
end

get '/admin/api/typing-capture' do
  content_type :json
  require_dashboard_read!

  limit = params['limit']&.to_i || 200
  limit = 500 if limit > 500
  limit = 1 if limit < 1

  clauses = []
  binds = []

  if params['user_id'] && !params['user_id'].to_s.strip.empty?
    user_id = parse_positive_int(params['user_id'])
    return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id.nil?
    binds << user_id
    clauses << "e.user_id = $#{binds.length}"
  end

  if params['context'] && !params['context'].to_s.strip.empty?
    binds << params['context'].to_s.strip[0, 64]
    clauses << "e.context = $#{binds.length}"
  end

  where_sql = clauses.empty? ? '' : "WHERE #{clauses.join(' AND ')}"
  binds << limit

  rows = DB.exec_params(
    "SELECT e.id, e.user_id, u.username, e.context, e.field_name, e.client_session_id,
            e.event_type, e.key_value, e.key_code, e.dwell_ms, e.flight_ms,
            e.typed_length, e.cursor_pos, e.client_ts_ms, e.ip_address,
            e.request_id, e.metadata, e.captured_at
     FROM typing_capture_events e
     LEFT JOIN users u ON u.id = e.user_id
     #{where_sql}
     ORDER BY e.captured_at DESC
     LIMIT $#{binds.length}",
    binds
  )

  events = rows.map do |row|
    {
      id: row['id'].to_i,
      user_id: row['user_id']&.to_i,
      username: row['username'],
      context: row['context'],
      field_name: row['field_name'],
      client_session_id: row['client_session_id'],
      event_type: row['event_type'],
      key_value: row['key_value'],
      key_code: row['key_code']&.to_i,
      dwell_ms: row['dwell_ms']&.to_f,
      flight_ms: row['flight_ms']&.to_f,
      typed_length: row['typed_length']&.to_i,
      cursor_pos: row['cursor_pos']&.to_i,
      client_ts_ms: row['client_ts_ms']&.to_i,
      ip_address: row['ip_address'],
      request_id: row['request_id'],
      metadata: begin
        raw = row['metadata']
        raw.nil? ? {} : JSON.parse(raw)
      rescue
        {}
      end,
      captured_at: row['captured_at']
    }
  end

  json_success({ status: 'SUCCESS', events: events, count: events.length })
rescue PG::UndefinedTable
  json_error('typing_capture_events table missing. Run migrations.', 503, 'TYPING_TABLE_MISSING')
rescue PG::Error => e
  $logger.error "Database error in /admin/api/typing-capture: #{e.message}"
  json_error('Database error')
rescue => e
  $logger.error "Unknown error in /admin/api/typing-capture: #{e.message}"
  json_error('Internal Server Error')
end

post '/admin/api/attempt/:id/label' do
  content_type :json
  require_dashboard_control!
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  attempt_id = parse_positive_int(params['id'])
  return json_error('Invalid attempt id', 400, 'INVALID_ATTEMPT') if attempt_id.nil?

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
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  payload_raw = request.body.read
  payload = payload_raw.nil? || payload_raw.strip.empty? ? {} : JSON.parse(payload_raw)
  label = normalize_attempt_label(payload['label'])
  return json_error('Label must be GENUINE, IMPOSTER, or UNLABELED', 400, 'INVALID_LABEL') if label == :invalid

  clauses = []
  params = []

  if payload.key?('user_id') && !payload['user_id'].to_s.strip.empty?
    user_id = parse_positive_int(payload['user_id'])
    return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id.nil?
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

  user_id = parse_positive_int(params['user_id'])
  return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id.nil?

  with_dashboard_service do |service|
    json_success(service.user_detail(user_id))
  end
end

post '/admin/api/recalibrate/:user_id' do
  content_type :json
  require_dashboard_control!
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  user_id = parse_positive_int(params['user_id'])
  return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id.nil?

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
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  user_id = parse_positive_int(params['user_id'])
  return json_error('Invalid user_id', 400, 'INVALID_USER') if user_id.nil?

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
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  body_data = request.body.read
  payload = body_data.nil? || body_data.strip.empty? ? {} : JSON.parse(body_data)

  if ENABLE_ASYNC_ADMIN_JOBS
    job_id = enqueue_admin_job('EXPORT_DATASET', {
      requested_by: session[:admin_user] || 'token-admin',
      format: payload['format'],
      user_id: payload['user_id'],
      from_time: payload['from_time'],
      to_time: payload['to_time'],
      outcome: payload['outcome']
    })

    log_audit_event(event_type: 'EXPORT_DATASET_QUEUED', actor: session[:admin_user] || 'token-admin', metadata: { job_id: job_id })
    return json_success({ status: 'QUEUED', job_id: job_id }, 202)
  end

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
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  if ENABLE_ASYNC_ADMIN_JOBS
    job_id = enqueue_admin_job('RUN_EVALUATION', { requested_by: session[:admin_user] || 'token-admin' })
    log_audit_event(event_type: 'RUN_EVALUATION_QUEUED', actor: session[:admin_user] || 'token-admin', metadata: { job_id: job_id })
    return json_success({ status: 'QUEUED', job_id: job_id }, 202)
  end

  service = EvaluationService.new(db: DB)
  report = service.evaluate_and_write

  log_audit_event(
    event_type: 'RUN_EVALUATION',
    actor: session[:admin_user] || 'token-admin',
    metadata: report
  )

  json_success({ status: 'SUCCESS', evaluation: report })
end

get '/admin/api/jobs/:job_id' do
  content_type :json
  require_dashboard_read!

  job_id = params['job_id'].to_s.strip
  return json_error('Invalid job_id', 400, 'INVALID_JOB') if job_id.empty?

  job = fetch_async_job(job_id)
  return json_error('Job not found', 404, 'JOB_NOT_FOUND') if job.nil?

  json_success({ status: 'SUCCESS', job: job })
end

post '/admin/api/cleanup-sessions' do
  content_type :json
  require_dashboard_control!
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  deleted = DB.exec('DELETE FROM user_sessions WHERE expires_at <= NOW()').cmd_tuples
  log_audit_event(
    event_type: 'CLEANUP_SESSIONS',
    actor: session[:admin_user] || 'token-admin',
    metadata: { deleted: deleted }
  )

  json_success({ status: 'SUCCESS', deleted_sessions: deleted })
end

post '/admin/api/apply-retention' do
  content_type :json
  require_dashboard_control!
  require_same_origin_for_cookie_session!(api: true)
  require_rate_limit!(
    scope: 'admin-api',
    key: client_ip,
    limit: ADMIN_API_RATE_LIMIT_MAX,
    window_seconds: ADMIN_API_RATE_LIMIT_WINDOW_SECONDS,
    message: 'Too many admin requests. Try again shortly.',
    code: 'ADMIN_RATE_LIMIT'
  )

  retention_days = DATA_RETENTION_DAYS

  deleted_attempts = DB.exec_params(
    "DELETE FROM biometric_attempts WHERE created_at < NOW() - ($1::int * INTERVAL '1 day')",
    [retention_days]
  ).cmd_tuples

  deleted_access_logs = DB.exec_params(
    "DELETE FROM access_logs WHERE attempted_at < NOW() - ($1::int * INTERVAL '1 day')",
    [retention_days]
  ).cmd_tuples

  deleted_scores = DB.exec_params(
    "DELETE FROM user_score_history WHERE created_at < NOW() - ($1::int * INTERVAL '1 day')",
    [retention_days]
  ).cmd_tuples

  log_audit_event(
    event_type: 'APPLY_RETENTION',
    actor: session[:admin_user] || 'token-admin',
    metadata: {
      retention_days: retention_days,
      deleted_attempts: deleted_attempts,
      deleted_access_logs: deleted_access_logs,
      deleted_scores: deleted_scores
    }
  )

  json_success({
    status: 'SUCCESS',
    retention_days: retention_days,
    deleted_attempts: deleted_attempts,
    deleted_access_logs: deleted_access_logs,
    deleted_scores: deleted_scores
  })
end

get '/health' do
  content_type :json
  json_success({ status: 'ok' })
end

get '/ready' do
  content_type :json

  db_ok = begin
    DB.exec('SELECT 1')
    true
  rescue
    false
  end

  redis_ok = if REDIS_URL.empty?
               'disabled'
             else
               begin
                 REDIS_CLIENT&.ping == 'PONG' ? 'ok' : 'unavailable'
               rescue
                 'unavailable'
               end
             end

  schema = schema_readiness
  is_ready = db_ok && schema[:ready] && (redis_ok == 'ok' || redis_ok == 'disabled')
  status_code = is_ready ? 200 : 503

  json_success({
    status: is_ready ? 'ready' : 'not_ready',
    checks: {
      database: db_ok ? 'ok' : 'failed',
      redis: redis_ok,
      schema: schema
    }
  }, status_code)
end

get '/metrics' do
  allowed = localhost_request? || admin_token_valid? || admin_authenticated?
  halt 403, json_error('Metrics access denied', 403, 'METRICS_FORBIDDEN') unless allowed

  content_type 'text/plain'
  snapshot = metrics_snapshot
  avg_ms = snapshot[:requests_total].zero? ? 0.0 : (snapshot[:request_duration_ms_total] / snapshot[:requests_total])

  lines = []
  lines << "biokey_requests_total #{snapshot[:requests_total]}"
  lines << "biokey_request_duration_ms_avg #{format('%.2f', avg_ms)}"
  lines << "biokey_request_duration_ms_max #{format('%.2f', snapshot[:request_duration_ms_max])}"
  lines << "biokey_auth_failures_total #{snapshot[:auth_failures_total]}"
  lines << "biokey_rate_limit_hits_total #{snapshot[:rate_limit_hits_total]}"

  snapshot[:responses_by_status].each do |status_code, count|
    lines << "biokey_responses_total{status=\"#{status_code}\"} #{count}"
  end

  lines << ''
  lines.join("\n")
end

options '*' do
  status 204
end