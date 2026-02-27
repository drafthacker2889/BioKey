require 'json'
require 'time'
require 'yaml'
require 'pg'

OUTPUT_DIR = File.expand_path('../exports', __dir__)
Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)

begin
  config_path = File.expand_path('../backend-server/config/database.yml', __dir__)
  cfg = YAML.load_file(config_path)['development']
rescue
  cfg = {}
end

conn = PG.connect(
  dbname: ENV['DB_NAME'] || cfg['database'] || 'biokey_db',
  user: ENV['DB_USER'] || cfg['user'] || 'postgres',
  password: ENV['DB_PASSWORD'] || cfg['password'] || 'change_me',
  host: ENV['DB_HOST'] || cfg['host'] || 'localhost'
)

limit = (ENV['TYPING_EXPORT_LIMIT'] || '50000').to_i
limit = 1000 if limit < 1000

rows = conn.exec_params(
  "SELECT e.id, e.user_id, u.username, e.context, e.field_name, e.client_session_id,
          e.event_type, e.key_value, e.key_code, e.dwell_ms, e.flight_ms,
          e.typed_length, e.cursor_pos, e.client_ts_ms, e.ip_address,
          e.request_id, e.metadata, e.captured_at
   FROM typing_capture_events e
   LEFT JOIN users u ON u.id = e.user_id
   ORDER BY e.captured_at DESC
   LIMIT $1",
  [limit]
)

payload = rows.map do |r|
  {
    id: r['id']&.to_i,
    user_id: r['user_id']&.to_i,
    username: r['username'],
    context: r['context'],
    field_name: r['field_name'],
    client_session_id: r['client_session_id'],
    event_type: r['event_type'],
    key_value: r['key_value'],
    key_code: r['key_code']&.to_i,
    dwell_ms: r['dwell_ms']&.to_f,
    flight_ms: r['flight_ms']&.to_f,
    typed_length: r['typed_length']&.to_i,
    cursor_pos: r['cursor_pos']&.to_i,
    client_ts_ms: r['client_ts_ms']&.to_i,
    ip_address: r['ip_address'],
    request_id: r['request_id'],
    metadata: begin
      raw = r['metadata']
      raw.nil? ? {} : JSON.parse(raw)
    rescue
      {}
    end,
    captured_at: r['captured_at']
  }
end

stamp = Time.now.utc.strftime('%Y%m%d_%H%M%S')
out_path = File.join(OUTPUT_DIR, "typing_dataset_#{stamp}.json")
File.write(out_path, JSON.pretty_generate(payload))

puts "Exported #{payload.length} typing events to #{out_path}"
