require 'sinatra'
require 'json'
require 'pg' # PostgreSQL driver

# Database Connection
DB = PG.connect(dbname: 'biokey_db', user: 'your_user')

# Route 1: The Enrollment (Training)
post '/train' do
  data = JSON.parse(request.body.read)
  user_id = data['user_id']
  timings = data['timings'] # Array of [dwell, flight]

  # Save each timing pair to SQL
  timings.each do |t|
    DB.exec_params("INSERT INTO biometric_profiles (user_id, key_pair, avg_dwell_time, avg_flight_time) 
                    VALUES ($1, $2, $3, $4)", [user_id, t['pair'], t['dwell'], t['flight']])
  end
  { status: "Profile Updated" }.to_json
end

# Route 2: The Login (Verification)
post '/login' do
  data = JSON.parse(request.body.read)
  # 1. Fetch the stored "Master Rhythm" from SQL 
  # 2. Compare it with the current attempt using the C Engine 
  # 3. Return 'Success' or 'Access Denied' [cite: 171]
end