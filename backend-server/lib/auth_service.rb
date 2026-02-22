require_relative 'math_engine'

class AuthService
  # Thresholds for decision making
  PERFECT_MATCH = 10.0   
  SUSPICIOUS    = 20.0   

  def self.normalize_attempt_timing(timing, index)
    if timing.is_a?(Hash)
      pair = timing['pair'] || "k#{index}"
      dwell = timing['dwell'] || timing['value'] || timing['time']
      flight = timing['flight'] || timing['dwell'] || timing['value'] || timing['time']
      return nil if dwell.nil? || flight.nil?

      return {
        'pair' => pair.to_s,
        'dwell' => dwell.to_f,
        'flight' => flight.to_f
      }
    end

    if timing.is_a?(Numeric)
      return {
        'pair' => "k#{index}",
        'dwell' => timing.to_f,
        'flight' => timing.to_f
      }
    end

    nil
  end

  def self.verify_login(user_id, attempt_data)
    # 1. Fetch the existing master profile
    # Included all columns from both versions (avg_dwell_time, avg_flight_time, sample_count, std_dev_flight)
    result = DB.exec_params(
      "SELECT key_pair, avg_dwell_time, avg_flight_time, sample_count, std_dev_flight 
       FROM biometric_profiles 
       WHERE user_id = $1", 
      [user_id]
    )
    
    if result.ntuples == 0
      return { status: "ERROR", message: "No profile found" }
    end

    # 2. Prepare the stored data for the C Engine
    # We need to ensure the order matches the attempt data or a consistent canonical order.
    # Assuming attempt_data is a list of timings, and we need to match them by key_pair?
    # Or assuming the native engine just takes two flat arrays of numbers?
    # The original implementation just flattened everything. Let's stick to that but do it safely.
    # BUT wait, the original implementation sorted by key_pair ASC. Use that.
    
    # Create a hash for easy lookup
    profile_map = {}
    result.each do |row|
      profile_map[row['key_pair']] = row
    end

    stored_profile_flat = []
    attempt_flat = []
    
    # We must iterate in a deterministic order. 
    # Let's trust the attempt_data's order if it contains key_pair, or sort them.
    # The request body has user_id and timings. 'timings' is an array of objects.
    # Let's assume we must process only keys that exist in both? Or all?
    # The native engine takes two float arrays. They must line up index-by-index.
    
    # Let's sort the attempt data by key_pair to match the DB sort (if we did that).
    # Better: iterate through the attempt data, look up the profile, if found, add both to flat arrays.
    
    normalized_attempts = attempt_data.each_with_index.map { |timing, index| normalize_attempt_timing(timing, index) }.compact

    normalized_attempts.each do |timing|
      key = timing['pair']
      if profile_map.key?(key)
        row = profile_map[key]
        
        # Add Dwell
        attempt_flat << timing['dwell'].to_f
        stored_profile_flat << row['avg_dwell_time'].to_f
        
        # Add Flight
        attempt_flat << timing['flight'].to_f
        stored_profile_flat << row['avg_flight_time'].to_f
      end
    end

    if stored_profile_flat.empty?
       return { status: "ERROR", message: "No matching keys found in profile" }
    end

    # 3. Call the C Math Engine
    distance_score = MathEngine.get_score(attempt_flat, stored_profile_flat)
    puts "Distance Score calculated by C: #{distance_score}" 

    # 4. Make the Verdict
    if distance_score < PERFECT_MATCH
      puts "Access Granted: Perfect Match."
      
      # 5. Adaptive learning: Update the profile with new data
      # Now we pass the FULL attempt data and the FULL profile map to update correctly
      update_profile(user_id, normalized_attempts, profile_map) 
      
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
  def self.update_profile(user_id, attempt_data, profile_map)
    puts "Updating biometric profile in SQL for user #{user_id}..."

    attempt_data.each do |timing|
      key = timing['pair']
      next unless profile_map.key?(key)

      current_row = profile_map[key]
      
      # Get current values from the database record
      n = current_row['sample_count'].to_i
      old_avg_dwell = current_row['avg_dwell_time'].to_f
      old_avg_flight = current_row['avg_flight_time'].to_f
      
      # New attempt values
      new_dwell = timing['dwell'].to_f
      new_flight = timing['flight'].to_f
  
      # Calculate Moving Averages
      updated_dwell = ((old_avg_dwell * n) + new_dwell) / (n + 1)
      updated_flight = ((old_avg_flight * n) + new_flight) / (n + 1)
      
      # Calculate Standard Deviation for Flight Time (Simple approximation)
      new_std_dev = Math.sqrt(((new_flight - updated_flight)**2))
  
      # Update the database with the recalculated statistics for THIS key pair
      DB.exec_params(
        "UPDATE biometric_profiles SET 
         avg_dwell_time = $1, 
         avg_flight_time = $2, 
         sample_count = $3,
         std_dev_flight = $4
         WHERE user_id = $5 AND key_pair = $6",
        [updated_dwell, updated_flight, n + 1, new_std_dev, user_id, key]
      )
    end
    puts "Profile updated for matching keys."
  end
end