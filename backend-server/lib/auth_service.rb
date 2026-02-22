class AuthService
  DEFAULT_SUCCESS_THRESHOLD = 1.75
  DEFAULT_CHALLENGE_THRESHOLD = 3.0

  MIN_MATCHED_PAIRS = 6
  MIN_COVERAGE_RATIO = 0.55
  MIN_FEATURE_STD = 15.0
  MAX_Z = 5.0
  HUBER_DELTA = 2.5

  CALIBRATION_MIN_SCORES = 10
  SCORE_HISTORY_LIMIT = 200
  ADAPTIVE_UPDATE_MAX_PAIRS = 160

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
    result = DB.exec_params(
      "SELECT key_pair, avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count, m2_dwell, m2_flight 
       FROM biometric_profiles 
       WHERE user_id = $1", 
      [user_id]
    )
    
    if result.ntuples == 0
      return { status: "ERROR", message: "No profile found" }
    end

    normalized_attempts = attempt_data.each_with_index.map { |timing, index| normalize_attempt_timing(timing, index) }.compact
    if normalized_attempts.empty?
      return { status: "ERROR", message: "No valid attempt timings supplied" }
    end

    profile_map = {}
    result.each do |row|
      profile_map[row['key_pair']] = row
    end

    matched = []
    normalized_attempts.each do |timing|
      key = timing['pair']
      if profile_map.key?(key)
        row = profile_map[key]

        matched << {
          pair: key,
          attempt_dwell: timing['dwell'].to_f,
          attempt_flight: timing['flight'].to_f,
          mean_dwell: row['avg_dwell_time'].to_f,
          mean_flight: row['avg_flight_time'].to_f,
          std_dwell: row['std_dev_dwell'].to_f,
          std_flight: row['std_dev_flight'].to_f,
          sample_count: row['sample_count'].to_i
        }
      end
    end

    matched_pairs = matched.length
    coverage_ratio = matched_pairs.to_f / normalized_attempts.length.to_f

    if matched_pairs < MIN_MATCHED_PAIRS
      score = DEFAULT_CHALLENGE_THRESHOLD + 1.0
      record_score(user_id, score, 'LOW_COVERAGE', coverage_ratio, matched_pairs)
      return {
        status: "ERROR",
        message: "Insufficient matched pairs",
        score: score,
        matched_pairs: matched_pairs,
        coverage_ratio: coverage_ratio.round(3)
      }
    end

    base_score = weighted_variance_aware_score(matched)
    coverage_penalty = coverage_ratio < MIN_COVERAGE_RATIO ? (1.0 + ((MIN_COVERAGE_RATIO - coverage_ratio) * 2.0)) : 1.0
    distance_score = base_score * coverage_penalty

    thresholds = calibrated_thresholds_for_user(user_id)

    if distance_score <= thresholds[:success]
      update_profile(user_id, normalized_attempts.take(ADAPTIVE_UPDATE_MAX_PAIRS))
      record_score(user_id, distance_score, 'SUCCESS', coverage_ratio, matched_pairs)
      return {
        status: "SUCCESS",
        score: distance_score.round(4),
        matched_pairs: matched_pairs,
        coverage_ratio: coverage_ratio.round(3),
        success_threshold: thresholds[:success].round(4),
        challenge_threshold: thresholds[:challenge].round(4)
      }
    elsif distance_score <= thresholds[:challenge]
      record_score(user_id, distance_score, 'CHALLENGE', coverage_ratio, matched_pairs)
      return {
        status: "CHALLENGE",
        score: distance_score.round(4),
        matched_pairs: matched_pairs,
        coverage_ratio: coverage_ratio.round(3),
        success_threshold: thresholds[:success].round(4),
        challenge_threshold: thresholds[:challenge].round(4)
      }
    else
      record_score(user_id, distance_score, 'DENIED', coverage_ratio, matched_pairs)
      return {
        status: "DENIED",
        score: distance_score.round(4),
        matched_pairs: matched_pairs,
        coverage_ratio: coverage_ratio.round(3),
        success_threshold: thresholds[:success].round(4),
        challenge_threshold: thresholds[:challenge].round(4)
      }
    end
  end

  def self.weighted_variance_aware_score(matched)
    weighted_loss_sum = 0.0
    weight_sum = 0.0

    matched.each do |feature|
      std_dwell = [feature[:std_dwell], MIN_FEATURE_STD].max
      std_flight = [feature[:std_flight], MIN_FEATURE_STD].max

      z_dwell = ((feature[:attempt_dwell] - feature[:mean_dwell]) / std_dwell).clamp(-MAX_Z, MAX_Z)
      z_flight = ((feature[:attempt_flight] - feature[:mean_flight]) / std_flight).clamp(-MAX_Z, MAX_Z)

      loss_dwell = huber_loss(z_dwell)
      loss_flight = huber_loss(z_flight)

      stability_weight = Math.log([feature[:sample_count], 2].max + 1.0)
      variance_weight = (1.0 / std_dwell) + (1.0 / std_flight)
      weight = [stability_weight * variance_weight, 0.01].max

      weighted_loss_sum += weight * (loss_dwell + loss_flight)
      weight_sum += weight * 2.0
    end

    return DEFAULT_CHALLENGE_THRESHOLD + 1.0 if weight_sum <= 0

    Math.sqrt(weighted_loss_sum / weight_sum)
  end

  def self.huber_loss(value)
    abs_value = value.abs
    return 0.5 * abs_value * abs_value if abs_value <= HUBER_DELTA

    HUBER_DELTA * (abs_value - 0.5 * HUBER_DELTA)
  end

  def self.median(values)
    return 0.0 if values.empty?

    sorted = values.sort
    mid = sorted.length / 2
    if sorted.length.odd?
      sorted[mid]
    else
      (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end

  def self.calibrated_thresholds_for_user(user_id)
    stored = DB.exec_params(
      'SELECT success_threshold, challenge_threshold FROM user_score_thresholds WHERE user_id = $1 LIMIT 1',
      [user_id]
    )

    successful_scores_result = DB.exec_params(
      "SELECT score
       FROM user_score_history
       WHERE user_id = $1 AND outcome = 'SUCCESS'
       ORDER BY created_at DESC
       LIMIT $2",
      [user_id, SCORE_HISTORY_LIMIT]
    )

    successful_scores = successful_scores_result.map { |row| row['score'].to_f }

    if successful_scores.length < CALIBRATION_MIN_SCORES
      if stored.ntuples > 0
        return {
          success: stored[0]['success_threshold'].to_f,
          challenge: stored[0]['challenge_threshold'].to_f
        }
      end

      return {
        success: DEFAULT_SUCCESS_THRESHOLD,
        challenge: DEFAULT_CHALLENGE_THRESHOLD
      }
    end

    med = median(successful_scores)
    absolute_deviations = successful_scores.map { |score| (score - med).abs }
    mad = median(absolute_deviations)
    robust_sigma = [1.4826 * mad, 0.20].max

    success_threshold = [med + (2.2 * robust_sigma), DEFAULT_SUCCESS_THRESHOLD * 0.75].max
    challenge_threshold = [med + (3.6 * robust_sigma), success_threshold + 0.4, DEFAULT_CHALLENGE_THRESHOLD * 0.75].max

    DB.exec_params(
      "INSERT INTO user_score_thresholds (user_id, success_threshold, challenge_threshold, updated_at)
       VALUES ($1, $2, $3, NOW())
       ON CONFLICT (user_id)
       DO UPDATE SET
         success_threshold = EXCLUDED.success_threshold,
         challenge_threshold = EXCLUDED.challenge_threshold,
         updated_at = NOW()",
      [user_id, success_threshold, challenge_threshold]
    )

    {
      success: success_threshold,
      challenge: challenge_threshold
    }
  end

  def self.record_score(user_id, score, outcome, coverage_ratio = nil, matched_pairs = nil)
    DB.exec_params(
      'INSERT INTO user_score_history (user_id, score, outcome, coverage_ratio, matched_pairs) VALUES ($1, $2, $3, $4, $5)',
      [user_id, score, outcome, coverage_ratio, matched_pairs]
    )
  rescue PG::Error => e
    warn "Failed to store score history for user #{user_id}: #{e.message}"
  end

  def self.update_running_stats(old_mean, old_m2, old_count, new_value)
    new_count = old_count + 1
    delta = new_value - old_mean
    new_mean = old_mean + (delta / new_count)
    delta2 = new_value - new_mean
    new_m2 = old_m2 + (delta * delta2)
    new_std = new_count > 1 ? Math.sqrt(new_m2 / (new_count - 1)) : 0.0

    {
      mean: new_mean,
      m2: new_m2,
      count: new_count,
      std: new_std
    }
  end

  def self.upsert_profile_pair(user_id, key, dwell, flight)
    DB.transaction do |conn|
      current = conn.exec_params(
        "SELECT avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count, m2_dwell, m2_flight
         FROM biometric_profiles
         WHERE user_id = $1 AND key_pair = $2
         FOR UPDATE",
        [user_id, key]
      )

      if current.ntuples == 0
        conn.exec_params(
          "INSERT INTO biometric_profiles (
             user_id, key_pair, avg_dwell_time, avg_flight_time, std_dev_dwell, std_dev_flight, sample_count, m2_dwell, m2_flight
           ) VALUES ($1, $2, $3, $4, 0, 0, 1, 0, 0)",
          [user_id, key, dwell, flight]
        )
        next
      end

      row = current[0]
      sample_count = row['sample_count'].to_i

      dwell_stats = update_running_stats(
        row['avg_dwell_time'].to_f,
        row['m2_dwell'].to_f,
        sample_count,
        dwell
      )

      flight_stats = update_running_stats(
        row['avg_flight_time'].to_f,
        row['m2_flight'].to_f,
        sample_count,
        flight
      )

      conn.exec_params(
        "UPDATE biometric_profiles
         SET avg_dwell_time = $1,
             avg_flight_time = $2,
             std_dev_dwell = $3,
             std_dev_flight = $4,
             sample_count = $5,
             m2_dwell = $6,
             m2_flight = $7
         WHERE user_id = $8 AND key_pair = $9",
        [
          dwell_stats[:mean],
          flight_stats[:mean],
          dwell_stats[:std],
          flight_stats[:std],
          dwell_stats[:count],
          dwell_stats[:m2],
          flight_stats[:m2],
          user_id,
          key
        ]
      )
    end
  end

  def self.update_profile(user_id, attempt_data)
    attempt_data.each do |timing|
      upsert_profile_pair(user_id, timing['pair'], timing['dwell'].to_f, timing['flight'].to_f)
    end
  end
end