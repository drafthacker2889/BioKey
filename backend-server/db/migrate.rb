require 'pg'
require 'yaml'

begin
  db_config = File.exist?(File.expand_path('../config/database.yml', __dir__)) ? YAML.load_file(File.expand_path('../config/database.yml', __dir__))['development'] : {}
rescue StandardError
  db_config = {}
end

db_name = ENV['DB_NAME'] || db_config['database'] || 'biokey_db'
db_user = ENV['DB_USER'] || db_config['user'] || 'postgres'
db_pass = ENV['DB_PASSWORD'] || db_config['password'] || 'change_me'
db_host = ENV['DB_HOST'] || db_config['host'] || 'localhost'

conn = PG.connect(dbname: db_name, user: db_user, password: db_pass, host: db_host)

conn.exec(<<~SQL)
  CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(64) PRIMARY KEY,
    applied_at TIMESTAMP DEFAULT NOW()
  )
SQL

migrations_dir = File.expand_path('migrations', __dir__)
files = Dir.glob(File.join(migrations_dir, '*.sql')).sort

files.each do |file|
  version = File.basename(file).split('_').first
  next if version.nil? || version.empty?

  already_applied = conn.exec_params('SELECT 1 FROM schema_migrations WHERE version = $1 LIMIT 1', [version]).ntuples > 0
  next if already_applied

  sql = File.read(file)
  conn.transaction do |tx|
    tx.exec(sql)
    tx.exec_params('INSERT INTO schema_migrations (version) VALUES ($1)', [version])
  end

  puts "Applied migration #{File.basename(file)}"
end

puts 'Migration run complete.'
