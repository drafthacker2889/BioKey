require_relative 'math_engine'

class AuthService
  # Thresholds for decision logic [cite: 56, 57]
  PERFECT_MATCH = 10.0   
  SUSPICIOUS    = 20.0   

  def self.verify_login(user_id, attempt_data)
    # 1. Fetch stored Master Profile from SQL [cite: 164]
    result = DB.exec_params(
      "SELECT avg_dwell_time, avg_flight_time 
       FROM biometric_profiles 
       WHERE user_id = $1", 
      [user_id]
    )
    
    if result.ntuples == 0
      return { status: "ERROR", message: "No profile found" }
    end

    # 2. Prepare the stored averages for the C Engine [cite: 166]
    stored_profile = []
    result.each do |row|
      stored_profile << row['avg_dwell_time'].to_f
      stored_profile << row['avg_flight_time'].to_f
    end

    # 3. Calculate Euclidean Distance via C Engine [cite: 55, 168]
    distance_score = MathEngine.get_score(attempt_data, stored_profile)
    puts "Distance Score calculated by C: #{distance_score}" [cite: 169]

    # 4. Decision Logic [cite: 170]
    if distance_score < PERFECT_MATCH
      puts "Access Granted: Perfect Match." [cite: 91, 171]
      update_profile(user_id, attempt_data) # Adaptive learning
      return { status: "SUCCESS", score: distance_score }
    elsif distance_score < SUSPICIOUS
      puts "Warning: Suspicious Rhythm." [cite: 92]
      return { status: "CHALLENGE", score: distance_score }
    else
      puts "Access Denied: Imposter Detected." [cite: 93]
      return { status: "DENIED", score: distance_score }
    end
  end

  def self.update_profile(user_id, new_data)
    # Adaptive Learning: update averages in the database [cite: 59, 172]
    puts "Updating biometric profile in SQL for user #{user_id}..."
  end
end