require_relative 'math_engine'

class AuthService
  PERFECT_MATCH = 10.0   
  SUSPICIOUS    = 20.0   

  def self.verify_login(user_id, attempt_data)
    result = DB.exec_params(
      "SELECT avg_dwell_time, avg_flight_time 
       FROM biometric_profiles 
       WHERE user_id = $1", 
      [user_id]
    )
    
    if result.ntuples == 0
      return { status: "ERROR", message: "No profile found" }
    end

    stored_profile = []
    result.each do |row|
      stored_profile << row['avg_dwell_time'].to_f
      stored_profile << row['avg_flight_time'].to_f
    end

    distance_score = MathEngine.get_score(attempt_data, stored_profile)
    puts "Distance Score calculated by C: #{distance_score}" 

    if distance_score < PERFECT_MATCH
      puts "Access Granted: Perfect Match."
      update_profile(user_id, attempt_data) # Adaptive learning
      return { status: "SUCCESS", score: distance_score }
    elsif distance_score < SUSPICIOUS
      puts "Warning: Suspicious Rhythm."
      return { status: "CHALLENGE", score: distance_score }
    else
      puts "Access Denied: Imposter Detected."
      return { status: "DENIED", score: distance_score }
    end
  end

  def self.update_profile(user_id, new_data)
    puts "Updating biometric profile in SQL for user #{user_id}..."
  end
end