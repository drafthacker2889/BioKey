require 'json'
require 'csv'
require 'fileutils'

class EvaluationService
  def initialize(db:)
    @db = db
  end

  def export_dataset(file_path:, format: 'json', user_id: nil, from_time: nil, to_time: nil, outcome: nil)
    rows = fetch_attempt_rows(user_id: user_id, from_time: from_time, to_time: to_time, outcome: outcome)

    FileUtils.mkdir_p(File.dirname(file_path))

    case format
    when 'csv'
      CSV.open(file_path, 'w') do |csv|
        csv << rows.first.keys if rows.any?
        rows.each { |row| csv << row.values }
      end
    else
      File.write(file_path, JSON.pretty_generate(rows))
    end

    {
      path: file_path,
      format: format,
      count: rows.length
    }
  end

  def evaluate_and_write(report_path: File.expand_path('../../docs/evaluation.md', __dir__))
    rows = fetch_attempt_rows.select { |row| !row['label'].nil? && !row['label'].strip.empty? }
    metrics = self.class.compute_metrics_from_rows(rows)

    FileUtils.mkdir_p(File.dirname(report_path))
    File.write(report_path, build_report_markdown(metrics, rows.length))

    store_report(metrics)

    {
      report_path: report_path,
      sample_count: rows.length,
      metrics: metrics
    }
  end

  def self.compute_metrics_from_rows(rows)
    normalized = rows.map do |row|
      {
        label: row['label'].to_s.upcase,
        outcome: row['outcome'].to_s.upcase
      }
    end

    genuine = normalized.select { |row| row[:label] == 'GENUINE' }
    imposter = normalized.select { |row| row[:label] == 'IMPOSTER' }

    false_accepts = imposter.count { |row| row[:outcome] == 'SUCCESS' }
    false_rejects = genuine.count { |row| row[:outcome] != 'SUCCESS' }

    far = imposter.empty? ? nil : false_accepts.to_f / imposter.length.to_f
    frr = genuine.empty? ? nil : false_rejects.to_f / genuine.length.to_f

    {
      genuine_count: genuine.length,
      imposter_count: imposter.length,
      false_accepts: false_accepts,
      false_rejects: false_rejects,
      far: far,
      frr: frr
    }
  end

  private

  def fetch_attempt_rows(user_id: nil, from_time: nil, to_time: nil, outcome: nil)
    clauses = []
    params = []

    if user_id
      params << user_id.to_i
      clauses << "user_id = $#{params.length}"
    end

    if outcome && !outcome.strip.empty?
      params << outcome.strip.upcase
      clauses << "outcome = $#{params.length}"
    end

    if from_time && !from_time.strip.empty?
      params << from_time
      clauses << "created_at >= $#{params.length}::timestamp"
    end

    if to_time && !to_time.strip.empty?
      params << to_time
      clauses << "created_at <= $#{params.length}::timestamp"
    end

    where_sql = clauses.empty? ? '' : "WHERE #{clauses.join(' AND ')}"

    @db.exec_params(
      "SELECT id, created_at, user_id, outcome, score, coverage_ratio, matched_pairs, ip_address, request_id, payload_hash, label
       FROM biometric_attempts
       #{where_sql}
       ORDER BY created_at DESC",
      params
    ).to_a
  end

  def build_report_markdown(metrics, sample_count)
    far_pct = metrics[:far].nil? ? 'N/A' : format('%.2f%%', metrics[:far] * 100.0)
    frr_pct = metrics[:frr].nil? ? 'N/A' : format('%.2f%%', metrics[:frr] * 100.0)

    <<~MD
      # BioKey Evaluation Report

      Generated at: #{Time.now.utc.iso8601}

      ## Dataset Summary

      - Labeled samples: #{sample_count}
      - Genuine samples: #{metrics[:genuine_count]}
      - Imposter samples: #{metrics[:imposter_count]}

      ## Metrics

      - FAR (False Accept Rate): #{far_pct}
      - FRR (False Reject Rate): #{frr_pct}
      - False accepts: #{metrics[:false_accepts]}
      - False rejects: #{metrics[:false_rejects]}

      ## Notes

      - FAR uses labeled `IMPOSTER` rows accepted as `SUCCESS`.
      - FRR uses labeled `GENUINE` rows not accepted as `SUCCESS`.
      - Add labels into `biometric_attempts.label` to make this report meaningful.
    MD
  end

  def store_report(metrics)
    @db.exec_params(
      'INSERT INTO evaluation_reports (report_type, sample_count, far, frr, metadata) VALUES ($1, $2, $3, $4, $5)',
      [
        'PHASE11_BASELINE',
        metrics[:genuine_count] + metrics[:imposter_count],
        metrics[:far],
        metrics[:frr],
        metrics.to_json
      ]
    )
  rescue PG::Error => e
    warn "Failed to store evaluation report: #{e.message}"
  end
end
