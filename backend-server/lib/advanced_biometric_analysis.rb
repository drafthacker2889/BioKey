# Advanced biometric analysis with machine learning-ready features
# Integrates novel techniques for improved accuracy and explainability

class AdvancedBiometricAnalysis
  # Statistical methods for novel keystroke dynamics evaluation

  # Covariate shift detector - identifies when user's behavior changes
  def self.detect_covariate_shift(current_samples, historical_samples, threshold = 0.3)
    return { shift_detected: false } if historical_samples.empty?

    # Kolmogorov-Smirnov test for distribution shift
    current_dwell = current_samples.map { |s| s['dwell'] }.compact.map(&:to_f).sort
    current_flight = current_samples.map { |s| s['flight'] }.compact.map(&:to_f).sort
    
    hist_dwell = historical_samples.map { |s| s['dwell'] }.compact.map(&:to_f).sort
    hist_flight = historical_samples.map { |s| s['flight'] }.compact.map(&:to_f).sort

    return { shift_detected: false, shift_score: 0.0, dwell_ks: 0.0, flight_ks: 0.0, recommendation: 'accept' } if current_dwell.empty? || current_flight.empty? || hist_dwell.empty? || hist_flight.empty?

    ks_dwell = kolmogorov_smirnov_statistic(current_dwell, hist_dwell)
    ks_flight = kolmogorov_smirnov_statistic(current_flight, hist_flight)

    shift_score = (ks_dwell + ks_flight) / 2.0

    {
      shift_detected: shift_score > threshold,
      shift_score: shift_score,
      dwell_ks: ks_dwell,
      flight_ks: ks_flight,
      recommendation: shift_score > threshold ? 'require_challenge' : 'accept'
    }
  end

  # Entropy-based keystroke pattern analysis
  # Higher entropy = more diverse typing, indicates new user/compromised account
  def self.keystroke_entropy(samples, bits_per_sample = 8)
    dwell_times = samples.map { |s| quantize_value(s['dwell'], bits_per_sample) }
    flight_times = samples.map { |s| quantize_value(s['flight'], bits_per_sample) }

    dwell_entropy = shannon_entropy(dwell_times)
    flight_entropy = shannon_entropy(flight_times)

    {
      dwell_entropy: dwell_entropy,
      flight_entropy: flight_entropy,
      total_entropy: dwell_entropy + flight_entropy,
      entropy_normalized: (dwell_entropy + flight_entropy) / (2.0 * bits_per_sample),
      expected_entropy: bits_per_sample  # Maximum possible
    }
  end

  # Temporal consistency check - typing speed changes within a session
  def self.temporal_consistency_analysis(samples_over_time)
    return { consistency_score: 1.0 } if samples_over_time.length < 2

    dwells = samples_over_time.map { |s| s['dwell'] }
    speed_changes = dwells.each_cons(2).map do |prev, curr|
      next 0 if prev == 0
      (curr - prev).abs / prev.to_f
    end

    avg_change = speed_changes.empty? ? 0 : speed_changes.sum / speed_changes.length
    consistency_score = Math.exp(-avg_change)  # 1.0 = perfect consistency, 0 = max change

    {
      consistency_score: consistency_score,
      avg_speed_change: avg_change,
      max_speed_change: speed_changes.max || 0,
      anomaly_detected: consistency_score < 0.5
    }
  end

  # Advanced biometric template aging
  # Accounts for natural variations as user ages their profile
  def self.template_age_factor(days_since_trained, half_life_days = 90)
    # Exponential decay: newer templates are more reliable
    decay_factor = 2.0 ** (-days_since_trained.to_f / half_life_days)
    
    {
      decay_factor: decay_factor,
      recommendation: decay_factor < 0.5 ? 'retrain_profile' : 'acceptable',
      days_since_trained: days_since_trained
    }
  end

  # Keystroke timing pattern uniqueness (fingerprint strength)
  # Lower score = more unique (harder to spoof), higher = more generic
  def self.pattern_uniqueness_score(profile_data)
    key_pairs = profile_data.map { |p| p['key_pair'] }
    
    # Diversity of trained key pairs
    unique_pairs = key_pairs.uniq.length
    pair_diversity = unique_pairs.to_f / key_pairs.length.to_f

    # Consistency of measurements
    dwells = profile_data.map { |p| p['avg_dwell_time'] }
    flights = profile_data.map { |p| p['avg_flight_time'] }
    
    dwell_cv = coefficient_of_variation(dwells)  # Lower CV = more consistent
    flight_cv = coefficient_of_variation(flights)

    # Calculate uniqueness (inverse of consistency + diversity bonus)
    consistency_penalty = (dwell_cv + flight_cv) / 2.0
    diversity_bonus = 1.0 - pair_diversity

    uniqueness = 1.0 - (consistency_penalty * 0.7 + diversity_bonus * 0.3)

    {
      uniqueness_score: [uniqueness, 0].max,  # Clamp to minimum 0
      pair_diversity: pair_diversity,
      dwell_consistency: 1.0 - dwell_cv,
      flight_consistency: 1.0 - flight_cv,
      spoofability_risk: uniqueness < 0.3 ? 'high' : uniqueness < 0.6 ? 'medium' : 'low'
    }
  end

  # Anomaly score combining multiple signals
  # Returns score 0-1: 0 = normal, 1 = definitely anomalous
  def self.multi_signal_anomaly_detection(current_attempt, profile, history)
    signals = []

    # Signal 1: Statistical distance
    statistical_distance = weighted_distance(current_attempt, profile)
    signals << { weight: 0.4, value: [statistical_distance, 1.0].min }

    # Signal 2: Consistency with recent attempts
    if history.any?
      consistency = temporal_consistency_analysis(history)
      signals << { weight: 0.2, value: 1.0 - consistency[:consistency_score] }
    end

    # Signal 3: Entropy spike detection
    entropy = keystroke_entropy([current_attempt] + (history.first(5) || []))
    signals << { weight: 0.2, value: entropy[:entropy_normalized] }

    # Signal 4: Covariate shift
    if history.length > 10
      shift = detect_covariate_shift([current_attempt], history)
      signals << { weight: 0.2, value: shift[:shift_detected] ? 0.8 : 0.2 }
    end

    # Weighted anomaly score
    total_weight = signals.sum { |s| s[:weight] }
    weighted_anomaly = signals.sum { |s| s[:value] * s[:weight] } / total_weight

    {
      anomaly_score: weighted_anomaly,
      anomalous: weighted_anomaly > 0.6,
      risk_level: weighted_anomaly > 0.8 ? 'critical' : weighted_anomaly > 0.6 ? 'high' : 'normal',
      signals: signals
    }
  end

  # Explainability: Break down why a decision was made
  def self.explain_decision(decision_result, score, thresholds)
    explanation = {
      decision: decision_result,
      confidence: (1.0 - (score - thresholds[:success]).abs / (thresholds[:challenge] - thresholds[:success])).clamp(0, 1),
      factors: []
    }

    if decision_result == 'CHALLENGE'
      explanation[:factors] << "Score #{score.round(2)} falls between success and challenge thresholds"
      explanation[:factors] << "Consider requesting additional verification (e.g., OTP, security questions)"
    elsif decision_result == 'SUCCESS'
      explanation[:factors] << "Score #{score.round(2)} within acceptable range"
      explanation[:factors] << "User biometric profile matches with high confidence"
    end

    explanation
  end

  private

  # Helper: Kolmogorov-Smirnov statistic between two distributions
  def self.kolmogorov_smirnov_statistic(sample1, sample2)
    return 0 if sample1.empty? || sample2.empty?

    merged_values = (sample1 + sample2).uniq.sort
    n1 = sample1.length.to_f
    n2 = sample2.length.to_f

    max_d = 0.0
    merged_values.each do |x|
      cdf1 = sample1.count { |v| v <= x } / n1
      cdf2 = sample2.count { |v| v <= x } / n2
      max_d = [max_d, (cdf1 - cdf2).abs].max
    end

    max_d
  end

  # Helper: Shannon entropy calculation
  def self.shannon_entropy(values)
    return 0 if values.empty?

    frequencies = {}
    values.each { |v| frequencies[v] = (frequencies[v] || 0) + 1 }

    entropy = 0
    values.length.to_f
    frequencies.each do |_, count|
      p = count.to_f / values.length
      entropy -= p * Math.log2(p) if p > 0
    end

    entropy
  end

  # Helper: Quantize continuous values to discrete bins
  def self.quantize_value(value, bits)
    # Normalize to 0-1 range assuming reasonable keystroke timing range
    normalized = [value / 500.0, 1.0].min  # Assume 500ms max reasonable
    (normalized * (2 ** bits)).to_i
  end

  # Helper: Coefficient of Variation (std dev / mean)
  def self.coefficient_of_variation(values)
    return 0 if values.empty? || values.all? { |v| v == 0 }

    mean = values.sum.to_f / values.length
    return 0 if mean == 0

    variance = values.sum { |v| (v - mean) ** 2 } / values.length
    std_dev = Math.sqrt(variance)

    std_dev / mean
  end

  # Helper: Weighted statistical distance
  def self.weighted_distance(attempt, profile)
    dwell_values = profile.map { |p| p['avg_dwell_time'] }.compact.map(&:to_f)
    flight_values = profile.map { |p| p['avg_flight_time'] }.compact.map(&:to_f)
    return 0.5 if dwell_values.empty? || flight_values.empty?

    dwell_mean = dwell_values.sum / dwell_values.length
    flight_mean = flight_values.sum / flight_values.length

    dwell_std = Math.sqrt(dwell_values.sum { |v| (v - dwell_mean) ** 2 } / [dwell_values.length, 1].max)
    flight_std = Math.sqrt(flight_values.sum { |v| (v - flight_mean) ** 2 } / [flight_values.length, 1].max)

    dwell_std = [dwell_std, 5.0].max
    flight_std = [flight_std, 5.0].max

    dwell_z = ((attempt['dwell'].to_f - dwell_mean) / dwell_std).abs
    flight_z = ((attempt['flight'].to_f - flight_mean) / flight_std).abs

    [[Math.sqrt((dwell_z**2 + flight_z**2) / 2.0) / 3.0, 1.0].min, 0.0].max
  end
end
