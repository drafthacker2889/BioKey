require_relative 'math_engine'

class AuthService
  # Thresholds for decision making
  PERFECT_MATCH = 10.0   
  SUSPICIOUS    = 20.0   

  def self.verify_login(user_id, attempt_data)
    # 1. Fetch the existing master profile
    # Included all columns from both versions (avg_dwell_time, avg_flight_time, sample_count, std_dev_flight)
    result = DB.exec_params(
      "SELECT avg_dwell_time, avg_flight_time, sample_count, std_dev_flight 
       FROM biometric_profiles 
       WHERE user_id = $1 
       ORDER BY key_pair ASC", 
      [user_id]
    )
    
    if result.ntuples == 0
      return { status: "ERROR", message: "No profile found" }
    end

    # 2. Prepare the stored data for the C Engine
    stored_profile = []
    
    # Version 1 used a loop for multiple key_pairs; Version 2 used the first row.
    # To be safe and comprehensive, we process the result set:
    result.each do |row|
      stored_profile << row['avg_dwell_time'].to_f
      stored_profile << row['avg_flight_time'].to_f
    end

    # 3. Call the C Math Engine
    distance_score = MathEngine.get_score(attempt_data, stored_profile)
    puts "Distance Score calculated by C: #{distance_score}" 

    # 4. Make the Verdict
    if distance_score < PERFECT_MATCH
      puts "Access Granted: Perfect Match."
      
      # 5. Adaptive learning: Update the profile with new data
      # Passing the first row to ensure 'sample_count' is available for math
      update_profile(user_id, attempt_data, result[0]) 
      
      return { status: "SUCCESS", score: distance_score }
    elsif distance_score < SUSPICIOUS
      puts "Warning: Suspicious Rhythm."
      return { status: "CHALLENGE", score: distance_score }
    else
      puts "Access Denied: Imposter Detected."
      return { status: "DENIED", score: distance_score }
    end
  end

  # The Statistical Logic for Adaptive Profiles
  def self.update_profile(user_id, new_data, current_row)
    puts "Updating biometric profile in SQL for user #{user_id}..."

    # Get current values from the database record
    n = current_row['sample_count'].to_i
    old_avg_dwell = current_row['avg_dwell_time'].to_f
    old_avg_flight = current_row['avg_flight_time'].to_f
    
    # New attempt values (from the attempt array: [dwell, flight])
    new_dwell = new_data[0]
    new_flight = new_data[1]

    # Calculate Moving Averages
    # Formula: ((Old Average * Count) + New Value) / (Count + 1)
    updated_dwell = ((old_avg_dwell * n) + new_dwell) / (n + 1)
    updated_flight = ((old_avg_flight * n) + new_flight) / (n + 1)
    
    # Calculate Standard Deviation for Flight Time
    # Simple version: how far the new flight is from the new average
    new_std_dev = Math.sqrt(((new_flight - updated_flight)**2))

    # Update the database with the recalculated statistics
    DB.exec_params(
      "UPDATE biometric_profiles SET 
       avg_dwell_time = $1, 
       avg_flight_time = $2, 
       sample_count = $3,
       std_dev_flight = $4
       WHERE user_id = $5",
      [updated_dwell, updated_flight, n + 1, new_std_dev, user_id]
    )
    puts "Profile updated: New Sample Count is #{n + 1}"
  end
end