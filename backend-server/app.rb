require 'sinatra'
require 'json'
require 'pg'
require 'yaml'
require_relative 'lib/auth_service'

# Load Database Configuration
db_config = YAML.load_file('config/database.yml')['development']
DB = PG.connect(
  dbname:   ENV['DB_NAME']     || db_config['database'], 
  user:     ENV['DB_USER']     || db_config['user'], 
  password: ENV['DB_PASSWORD'] || db_config['password'],
  host:     ENV['DB_HOST']     || db_config['host']
)

# Route 1: The Enrollment (Training)
post '/train' do
  content_type :json
  data = JSON.parse(request.body.read)
  user_id = data['user_id']
  timings = data['timings'] # Array of [dwell, flight]

  timings.each do |t|
    DB.exec_params(
      "INSERT INTO biometric_profiles (user_id, key_pair, avg_dwell_time, avg_flight_time) 
       VALUES ($1, $2, $3, $4)", 
      [user_id, t['pair'], t['dwell'], t['flight']]
    )
  end
  { status: "Profile Updated" }.to_json
end

# Route 2: The Login (Verification)
post '/login' do
  content_type :json
  data = JSON.parse(request.body.read)
  
  result = AuthService.verify_login(data['user_id'], data['timings'])
  
  result.to_json
end