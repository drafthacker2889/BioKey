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
  timings = data['timings']

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
  { status: "Profile Updated" }.to_json
end

# Route 2: The Login (Verification)
post '/login' do
  content_type :json
  data = JSON.parse(request.body.read)
  
  result = AuthService.verify_login(data['user_id'], data['timings'])
  
  result.to_json
end