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

format = (ARGV[0] || 'json').downcase
format = 'json' unless %w[json csv].include?(format)
output = ARGV[1] || File.expand_path("../exports/manual_dataset_#{Time.now.utc.strftime('%Y%m%d_%H%M%S')}.#{format}", __dir__)

service = EvaluationService.new(db: db)
result = service.export_dataset(file_path: output, format: format)
puts "Exported #{result[:count]} rows to #{result[:path]}"
