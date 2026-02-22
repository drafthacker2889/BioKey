require_relative '../backend-server/lib/evaluation_service'
require 'pg'
require 'yaml'

config_path = File.expand_path('../backend-server/config/database.yml', __dir__)
config = File.exist?(config_path) ? YAML.load_file(config_path)['development'] : {}

db = PG.connect(
  dbname: ENV['DB_NAME'] || config['database'] || 'biokey_db',
  user: ENV['DB_USER'] || config['user'] || 'postgres',
  password: ENV['DB_PASSWORD'] || config['password'] || 'change_me',
  host: ENV['DB_HOST'] || config['host'] || 'localhost'
)

report_path = ARGV[0] || File.expand_path('../docs/evaluation.md', __dir__)
service = EvaluationService.new(db: db)
result = service.evaluate_and_write(report_path: report_path)
puts "Evaluation report written to #{result[:report_path]} (samples=#{result[:sample_count]})"
