require 'sinatra'
require 'json'
require 'pg'
require 'yaml'
require 'logger'
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

def ensure_user_exists(user_id)
  existing = DB.exec_params("SELECT id FROM users WHERE id = $1 LIMIT 1", [user_id])
  return if existing.ntuples > 0

  DB.exec_params(
    "INSERT INTO users (id, username, password_hash) VALUES ($1, $2, $3)",
    [user_id, "user_#{user_id}", "demo_password_hash"]
  )
end

# Route 1: The Enrollment (Training)
post '/train' do
  content_type :json
  begin
    data = JSON.parse(request.body.read)
    user_id = data['user_id']
    timings = data['timings']

    if user_id.nil? || timings.nil? || !timings.is_a?(Array)
       return json_error("Invalid input data", 400)
    end

     ensure_user_exists(user_id)

    timings.each do |t|
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
        [user_id, t['pair'], t['dwell'], t['flight']]
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
    user_id = data['user_id']
    timings = data['timings']
    
    if user_id.nil? || timings.nil?
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