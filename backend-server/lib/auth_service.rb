require_relative 'math_engine'

class AuthService
  # The "Thresholds" - Adjust these based on how strict you want the security to be
  PERFECT_MATCH = 10.0   # [cite: 56]
  SUSPICIOUS    = 20.0   # [cite: 57]

  def self.verify_login(user_id, attempt_data)
    # 1. Fetch the stored Master Profile from SQL [cite: 164, 165]
    # (In a real app, you'd run: SELECT avg_dwell, avg_flight FROM biometric_profiles WHERE user_id = id)
    # For now, let's assume we have retrieved the profile array:
    stored_profile = [90.0, 150.0, 80.0, 100.0] 

    # 2. Use the C Engine to calculate the Euclidean Distance [cite: 55, 168]
    distance_score = MathEngine.get_score(attempt_data, stored_profile)
    puts "Distance Score calculated by C: #{distance_score}" # [cite: 169]

    # 3. Decision Logic [cite: 170]
    if distance_score < PERFECT_MATCH
      puts "Access Granted: Perfect Match." # [cite: 171, 91]
      update_profile(user_id, attempt_data) # Adaptive learning 
      return { status: "SUCCESS", score: distance_score }
    elsif distance_score < SUSPICIOUS
      puts "Warning: Suspicious Rhythm. 2FA Required." # [cite: 57, 92]
      return { status: "CHALLENGE", score: distance_score }
    else
      puts "Access Denied: Imposter Detected." # [cite: 58, 93]
      return { status: "DENIED", score: distance_score }
    end
  end

  def self.update_profile(user_id, new_data)
    # Logic to mix the new timing into the SQL averages 
    puts "Updating biometric profile in SQL for user #{user_id}..."
  end
end