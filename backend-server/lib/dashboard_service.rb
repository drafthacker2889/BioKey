class DashboardService
  def initialize(db:, uptime_seconds:)
    @db = db
    @uptime_seconds = uptime_seconds
  end

  def overview(can_control: false, is_admin: false)
    {
      db_connected: db_connected?,
      uptime_seconds: @uptime_seconds.to_i,
      attempts_24h: count_attempts("NOW() - INTERVAL '24 hours'"),
      attempts_7d: count_attempts("NOW() - INTERVAL '7 days'"),
      outcomes_7d: outcomes_breakdown,
      avg_coverage_24h: avg_coverage_24h,
      rate_limit_hits_24h: verdict_count("('AUTH_RATE','REG_RATE')", "NOW() - INTERVAL '24 hours'"),
      lockouts_24h: verdict_count("('AUTH_LOCK')", "NOW() - INTERVAL '24 hours'"),
      can_control: can_control,
      is_admin: is_admin
    }
  end

  def latest_attempts(limit: 50)
    rows = @db.exec_params(
      "SELECT id, user_id, outcome, score, coverage_ratio, matched_pairs, ip_address, request_id, created_at
       FROM biometric_attempts
       ORDER BY created_at DESC
       LIMIT $1",
      [limit]
    )

    rows.map do |row|
      {
        id: row['id'].to_i,
        user_id: row['user_id']&.to_i,
        outcome: row['outcome'],
        score: row['score']&.to_f,
        coverage_ratio: row['coverage_ratio']&.to_f,
        matched_pairs: row['matched_pairs']&.to_i,
        ip_address: row['ip_address'],
        request_id: row['request_id'],
        created_at: row['created_at']
      }
    end
  end

  def user_detail(user_id)
    thresholds_row = @db.exec_params(
      'SELECT success_threshold, challenge_threshold, updated_at FROM user_score_thresholds WHERE user_id = $1 LIMIT 1',
      [user_id]
    )

    success_count = @db.exec_params(
      "SELECT COUNT(*) AS c FROM user_score_history WHERE user_id = $1 AND outcome = 'SUCCESS'",
      [user_id]
    )[0]['c'].to_i

    score_trend = @db.exec_params(
      'SELECT score, outcome, created_at FROM user_score_history WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50',
      [user_id]
    ).map do |row|
      { score: row['score'].to_f, outcome: row['outcome'], created_at: row['created_at'] }
    end

    coverage_trend = @db.exec_params(
      'SELECT coverage_ratio, matched_pairs, created_at FROM biometric_attempts WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50',
      [user_id]
    ).map do |row|
      { coverage_ratio: row['coverage_ratio']&.to_f, matched_pairs: row['matched_pairs']&.to_i, created_at: row['created_at'] }
    end

    top_pairs = @db.exec_params(
      'SELECT key_pair, sample_count FROM biometric_profiles WHERE user_id = $1 ORDER BY sample_count DESC NULLS LAST LIMIT 15',
      [user_id]
    ).map do |row|
      { key_pair: row['key_pair'], sample_count: row['sample_count'].to_i }
    end

    threshold_payload = if thresholds_row.ntuples > 0
      {
        success_threshold: thresholds_row[0]['success_threshold'].to_f,
        challenge_threshold: thresholds_row[0]['challenge_threshold'].to_f,
        updated_at: thresholds_row[0]['updated_at']
      }
    else
      nil
    end

    {
      user_id: user_id,
      thresholds: threshold_payload,
      calibration_success_count: success_count,
      calibration_min_scores: AuthService::CALIBRATION_MIN_SCORES,
      score_trend: score_trend,
      coverage_trend: coverage_trend,
      top_key_pairs: top_pairs
    }
  end

  private

  def db_connected?
    @db.exec('SELECT 1')
    true
  rescue PG::Error
    false
  end

  def count_attempts(cutoff_sql)
    @db.exec("SELECT COUNT(*) AS c FROM biometric_attempts WHERE created_at > #{cutoff_sql}")[0]['c'].to_i
  end

  def outcomes_breakdown
    rows = @db.exec(
      "SELECT outcome, COUNT(*) AS c
       FROM biometric_attempts
       WHERE created_at > NOW() - INTERVAL '7 days'
       GROUP BY outcome"
    )

    payload = Hash.new(0)
    rows.each { |row| payload[row['outcome']] = row['c'].to_i }
    payload
  end

  def avg_coverage_24h
    value = @db.exec(
      "SELECT AVG(coverage_ratio) AS avg_cov
       FROM biometric_attempts
       WHERE created_at > NOW() - INTERVAL '24 hours'"
    )[0]['avg_cov']

    return nil if value.nil?

    value.to_f.round(4)
  end

  def verdict_count(verdict_sql, cutoff_sql)
    @db.exec(
      "SELECT COUNT(*) AS c
       FROM access_logs
       WHERE verdict IN #{verdict_sql}
         AND attempted_at > #{cutoff_sql}"
    )[0]['c'].to_i
  end
end
