require 'json'
require 'securerandom'
require 'time'
require 'rack/test'

ENV['RACK_ENV'] = 'test'
ENV['ADMIN_TOKEN'] ||= 'phase11-admin-token'
ENV['APP_SESSION_SECRET'] ||= '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

require_relative '../backend-server/app'

class MockLoad20Users
  include Rack::Test::Methods

  BASE_TIMINGS = [
    { pair: 'ab', dwell: 100, flight: 60 },
    { pair: 'bc', dwell: 110, flight: 62 },
    { pair: 'cd', dwell: 95, flight: 59 },
    { pair: 'de', dwell: 105, flight: 61 },
    { pair: 'ef', dwell: 102, flight: 58 },
    { pair: 'fg', dwell: 108, flight: 63 }
  ].freeze

  def app
    Sinatra::Application
  end

  def run(users_count: 20, logins_per_user: 7)
    started_at = Time.now
    before_overview = fetch_overview
    per_user = []

    users_count.times do |index|
      username = "mock_user_#{started_at.to_i}_#{index + 1}_#{SecureRandom.hex(3)}"
      password = "MockPass!#{SecureRandom.hex(5)}"

      register_user(username, password)
      user_id = authenticate_user(username, password)
      train_user(user_id, jitter: 0.0)

      statuses = []
      logins_per_user.times do |attempt_index|
        jitter = ((attempt_index % 3) - 1) * 0.02
        statuses << biometric_login(user_id, jitter: jitter)
      end

      per_user << {
        username: username,
        user_id: user_id,
        login_attempts: statuses.count,
        outcomes: statuses.tally
      }
    end

    after_overview = fetch_overview
    recent_feed = fetch_feed(limit: users_count * logins_per_user)

    print_report(
      started_at: started_at,
      finished_at: Time.now,
      per_user: per_user,
      before_overview: before_overview,
      after_overview: after_overview,
      recent_feed: recent_feed
    )
  end

  private

  def json_headers(extra = {})
    { 'CONTENT_TYPE' => 'application/json' }.merge(extra)
  end

  def parse_json!(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    raise "Response is not valid JSON: #{raw.inspect}"
  end

  def expect_status!(expected, context)
    return if last_response.status == expected

    raise "#{context} failed: expected HTTP #{expected}, got #{last_response.status}, body=#{last_response.body}"
  end

  def register_user(username, password)
    post '/v1/auth/register', { username: username, password: password }.to_json, json_headers
    expect_status!(200, "register #{username}")
  end

  def authenticate_user(username, password)
    post '/v1/auth/login', { username: username, password: password }.to_json, json_headers
    expect_status!(200, "auth/login #{username}")
    body = parse_json!(last_response.body)
    body.fetch('user_id').to_i
  end

  def train_user(user_id, jitter: 0.0)
    payload = { user_id: user_id, timings: timing_payload(jitter: jitter) }
    post '/v1/train', payload.to_json, json_headers
    expect_status!(200, "train user_id=#{user_id}")
  end

  def biometric_login(user_id, jitter: 0.0)
    payload = { user_id: user_id, timings: timing_payload(jitter: jitter) }
    post '/v1/login', payload.to_json, json_headers
    expect_status!(200, "biometric login user_id=#{user_id}")
    body = parse_json!(last_response.body)
    body.fetch('status')
  end

  def fetch_overview
    get '/admin/api/overview', {}, { 'HTTP_X_ADMIN_TOKEN' => ENV.fetch('ADMIN_TOKEN') }
    expect_status!(200, 'admin overview')
    parse_json!(last_response.body)
  end

  def fetch_feed(limit:)
    get "/admin/api/feed?limit=#{limit}", {}, { 'HTTP_X_ADMIN_TOKEN' => ENV.fetch('ADMIN_TOKEN') }
    expect_status!(200, 'admin feed')
    parse_json!(last_response.body)
  end

  def timing_payload(jitter:)
    BASE_TIMINGS.map do |sample|
      {
        pair: sample[:pair],
        dwell: (sample[:dwell] * (1.0 + jitter)).round(2),
        flight: (sample[:flight] * (1.0 + jitter)).round(2)
      }
    end
  end

  def print_report(started_at:, finished_at:, per_user:, before_overview:, after_overview:, recent_feed:)
    duration = (finished_at - started_at).round(2)
    total_attempts = per_user.sum { |row| row[:login_attempts] }
    unique_users = per_user.count
    all_minimum_met = per_user.all? { |row| row[:login_attempts] >= 7 }

    aggregate_outcomes = Hash.new(0)
    per_user.each do |row|
      row[:outcomes].each { |k, v| aggregate_outcomes[k] += v }
    end

    attempts_before = before_overview['attempts_24h'].to_i
    attempts_after = after_overview['attempts_24h'].to_i
    attempts_delta = attempts_after - attempts_before

    puts "=== Mock Load Report ==="
    puts "Started: #{started_at.utc.iso8601}"
    puts "Finished: #{finished_at.utc.iso8601}"
    puts "Duration: #{duration}s"
    puts
    puts "Users created: #{unique_users}"
    puts "Biometric logins executed: #{total_attempts}"
    puts "Minimum 7 logins per user met: #{all_minimum_met}"
    puts "Outcome distribution: #{aggregate_outcomes}"
    puts
    puts "Admin overview attempts_24h before: #{attempts_before}"
    puts "Admin overview attempts_24h after:  #{attempts_after}"
    puts "Admin overview attempts_24h delta:  #{attempts_delta}"
    puts "Recent feed entries fetched: #{(recent_feed['attempts'] || []).size}"
    puts

    per_user.each do |row|
      puts "- #{row[:username]} (user_id=#{row[:user_id]}): attempts=#{row[:login_attempts]}, outcomes=#{row[:outcomes]}"
    end
  end
end

MockLoad20Users.new.run(users_count: 20, logins_per_user: 7)
