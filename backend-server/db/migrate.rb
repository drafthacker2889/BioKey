require 'pg'
require 'yaml'
require 'optparse'

begin
  db_path = File.expand_path('../config/database.yml', __dir__)
  if File.exist?(db_path)
    loaded = if YAML.respond_to?(:safe_load_file)
               YAML.safe_load_file(db_path, permitted_classes: [], aliases: false)
             else
               YAML.safe_load(File.read(db_path), permitted_classes: [], aliases: false)
             end
    db_config = loaded.is_a?(Hash) ? (loaded['development'] || {}) : {}
  else
    db_config = {}
  end
rescue StandardError
  db_config = {}
end

db_name = ENV['DB_NAME'] || db_config['database'] || 'biokey_db'
db_user = ENV['DB_USER'] || db_config['user'] || 'postgres'
db_pass = ENV['DB_PASSWORD'] || db_config['password']
db_host = ENV['DB_HOST'] || db_config['host'] || 'localhost'

if ENV.fetch('APP_ENV', ENV.fetch('RACK_ENV', 'development')) == 'production' && db_pass.to_s.empty?
  abort('DB_PASSWORD is required in production for migrations')
end

options = { direction: 'up', target: nil }
OptionParser.new do |opts|
  opts.on('--down', 'Rollback the latest applied migration') { options[:direction] = 'down' }
  opts.on('--target VERSION', 'Migrate to a specific version (up only)') { |value| options[:target] = value }
end.parse!(ARGV)

conn = PG.connect(dbname: db_name, user: db_user, password: db_pass, host: db_host)

conn.exec(<<~SQL)
  CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(64) PRIMARY KEY,
    applied_at TIMESTAMP DEFAULT NOW()
  )
SQL

migrations_dir = File.expand_path('migrations', __dir__)
files = Dir.glob(File.join(migrations_dir, '*.sql')).sort

def migration_version(file)
  File.basename(file).split('_').first
end

def down_migration_file(file)
  base = File.basename(file)
  dir = File.dirname(file)
  candidate = File.join(dir, base.sub(/\.sql\z/, '.down.sql'))
  File.exist?(candidate) ? candidate : nil
end

if options[:direction] == 'down'
  last = conn.exec('SELECT version FROM schema_migrations ORDER BY applied_at DESC, version DESC LIMIT 1')
  if last.ntuples == 0
    puts 'No migrations to rollback.'
    exit(0)
  end

  version = last[0]['version']
  file = files.find { |candidate| migration_version(candidate) == version }
  rollback_file = file && down_migration_file(file)
  unless rollback_file
    abort "No rollback file found for migration #{version}"
  end

  sql = File.read(rollback_file)
  conn.transaction do |tx|
    tx.exec(sql)
    tx.exec_params('DELETE FROM schema_migrations WHERE version = $1', [version])
  end

  puts "Rolled back migration #{File.basename(file)}"
  puts 'Migration rollback complete.'
  exit(0)
end

files.each do |file|
  version = migration_version(file)
  next if version.nil? || version.empty?

  already_applied = conn.exec_params('SELECT 1 FROM schema_migrations WHERE version = $1 LIMIT 1', [version]).ntuples > 0
  next if already_applied

  next if !options[:target].nil? && version > options[:target]

  sql = File.read(file)
  conn.transaction do |tx|
    tx.exec(sql)
    tx.exec_params('INSERT INTO schema_migrations (version) VALUES ($1)', [version])
  end

  puts "Applied migration #{File.basename(file)}"
end

puts 'Migration run complete.'
