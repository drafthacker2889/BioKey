require 'sinatra'
require 'json'
require 'pg'
require 'yaml'
require_relative 'lib/auth_service'

# Load Database Configuration
db_config = YAML.load_file('config/database.yml')['development']
DB = PG.connect(
  dbname: db_config['database'], 
  user: db_config['user'], 
  password: db_config['password'],
  host: db_config['host']
)

# Route 1: The Enrollment (Training)
post '/train' do
  content_type :json
  data = JSON.parse(request.body.read)
  user_id = data['user_id']
  timings = data['timings'] # Array of [dwell, flight]

  # Save each timing pair to SQL biometric_profiles table [cite: 140]
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
  
  # Pass user ID and attempt timings to the AuthService logic [cite: 55, 170]
  result = AuthService.verify_login(data['user_id'], data['timings'])
  
  result.to_json
end