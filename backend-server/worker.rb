require 'json'
require 'pg'
require 'yaml'
require 'redis'
require 'securerandom'
require 'time'
require_relative 'lib/evaluation_service'

def safe_load_db_config
  path = File.expand_path('config/database.yml', __dir__)
  return {} unless File.exist?(path)

  loaded = if YAML.respond_to?(:safe_load_file)
             YAML.safe_load_file(path, permitted_classes: [], aliases: false)
           else
             YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
           end

  loaded.is_a?(Hash) ? (loaded['development'] || {}) : {}
rescue StandardError
  {}
end

def connect_db!
  db_config = safe_load_db_config

  db_name = ENV['DB_NAME'] || db_config['database'] || 'biokey_db'
  db_user = ENV['DB_USER'] || db_config['user'] || 'postgres'
  db_pass = ENV['DB_PASSWORD'] || db_config['password']
  db_host = ENV['DB_HOST'] || db_config['host'] || 'localhost'

  PG.connect(dbname: db_name, user: db_user, password: db_pass, host: db_host)
end

def redis_client
  url = ENV['REDIS_URL'].to_s.strip
  return nil if url.empty?

  client = Redis.new(url: url, connect_timeout: 1.5, read_timeout: 2, write_timeout: 2)
  client.ping
  client
rescue StandardError => e
  warn "Redis unavailable for worker: #{e.message}"
  nil
end

def set_job_status(redis, db, job_id, status, result: nil)
  timestamp = Time.now.utc.iso8601

  if redis
    update = {
      'status' => status.to_s,
      'updated_at' => timestamp
    }
    update['result'] = JSON.generate(result) unless result.nil?
    redis.hset("biokey:jobs:#{job_id}", update)
  else
    db.exec_params(
      'UPDATE async_jobs SET status = $2, result = $3::jsonb, updated_at = NOW() WHERE id = $1',
      [job_id, status.to_s, result.nil? ? nil : JSON.generate(result)]
    )
  end
end

def process_job(redis, db, job)
  job_id = job['job_id'].to_s
  job_type = job['job_type'].to_s
  payload = job['payload'].is_a?(Hash) ? job['payload'] : {}

  return if job_id.empty? || job_type.empty?

  set_job_status(redis, db, job_id, 'running')

  service = EvaluationService.new(db: db)
  result_payload = case job_type
                   when 'EXPORT_DATASET'
                     format = payload['format'].to_s.downcase
                     format = 'json' unless %w[json csv].include?(format)
                     suffix = Time.now.utc.strftime('%Y%m%d_%H%M%S')
                     extension = format == 'csv' ? 'csv' : 'json'
                     output_path = File.expand_path("../exports/dataset_#{suffix}.#{extension}", __dir__)

                     service.export_dataset(
                       file_path: output_path,
                       format: format,
                       user_id: payload['user_id'],
                       from_time: payload['from_time'],
                       to_time: payload['to_time'],
                       outcome: payload['outcome']
                     )
                   when 'RUN_EVALUATION'
                     service.evaluate_and_write
                   else
                     raise "Unsupported job_type: #{job_type}"
                   end

  set_job_status(redis, db, job_id, 'completed', result: {
    status: 'SUCCESS',
    completed_at: Time.now.utc.iso8601,
    output: result_payload
  })
rescue StandardError => e
  set_job_status(redis, db, job_id, 'failed', result: {
    status: 'ERROR',
    message: e.message,
    failed_at: Time.now.utc.iso8601
  })
end

def next_db_job(db)
  result = nil
  db.transaction do |tx|
    row = tx.exec(
      "SELECT id, job_type, payload
       FROM async_jobs
       WHERE status = 'queued'
       ORDER BY created_at ASC
       LIMIT 1
       FOR UPDATE SKIP LOCKED"
    )[0]

    if row
      tx.exec_params('UPDATE async_jobs SET status = $2, updated_at = NOW() WHERE id = $1', [row['id'], 'running'])
      result = {
        'job_id' => row['id'],
        'job_type' => row['job_type'],
        'payload' => begin
          raw = row['payload']
          raw.nil? || raw.empty? ? {} : JSON.parse(raw)
        rescue
          {}
        end
      }
    end
  end
  result
rescue StandardError => e
  warn "Failed to fetch queued DB job: #{e.message}"
  nil
end

running = true
Signal.trap('INT') { running = false }
Signal.trap('TERM') { running = false }

db = connect_db!
redis = redis_client

puts "BioKey async worker started (redis=#{redis.nil? ? 'disabled' : 'enabled'})"

while running
  if redis
    begin
      raw = redis.brpop('biokey:jobs:queue', timeout: 5)
      if raw && raw[1]
        job = JSON.parse(raw[1])
        process_job(redis, db, job)
      end
    rescue StandardError => e
      warn "Redis worker loop error: #{e.message}"
    end
  else
    job = next_db_job(db)
    if job
      process_job(nil, db, job)
    else
      sleep 2
    end
  end
end

puts 'BioKey async worker shutting down'
db.close if db
