require 'json'
require 'securerandom'
require 'time'
require 'rack/test'

# This script generates mixed traffic for ~2 minutes:
# - Genuine users: biometric training + repeated biometric logins (BIO SUCCESS/CHALLENGE/etc)
# - Attacker: repeated password logins to trigger AUTH_FAIL, AUTH_LOCK, AUTH_RATE

ENV['RACK_ENV'] = 'test'
ENV['ADMIN_TOKEN'] ||= 'phase11-admin-token'
ENV['APP_SESSION_SECRET'] ||= '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

require_relative '../backend-server/app'

class LiveDemo2Min
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

  def run(duration_seconds: 120)
    started_at = Time.now
    ends_at = started_at + duration_seconds

    puts "=== Live Demo (#{duration_seconds}s) ==="
    puts "Dashboard: http://127.0.0.1:4567/admin"
    puts "Watch Live Feed for mixed BIO/AUTH events"
    puts

    genuine_users = 2.times.map { create_and_train_user(prefix: 'genuine') }

    attacker_target = genuine_users.first
    attacker_password = 'WrongPass!999'

    puts "Genuine users:"
    genuine_users.each { |u| puts "- #{u[:username]} (user_id=#{u[:user_id]})" }
    puts
    puts "Attacker target: #{attacker_target[:username]} (user_id=#{attacker_target[:user_id]})"
    puts

    iteration = 0
    while Time.now < ends_at
      iteration += 1

      # Genuine biometric logins: keep them steady so you always see BIO events.
      genuine_users.each_with_index do |u, index|
        jitter = (((iteration + index) % 3) - 1) * 0.02
        status = biometric_login(u[:user_id], jitter: jitter)
        puts "BIO #{u[:username]} => #{status}" if (iteration % 6).zero?
      end

      # Attacker: always attempt once, plus periodic bursts to hit rate limiting.
      code = auth_login(attacker_target[:username], attacker_password)
      puts "AUTH attack attempt => HTTP #{code}" if (iteration % 6).zero?

      if (iteration % 5).zero?
        burst_results = []
        10.times { burst_results << auth_login(attacker_target[:username], attacker_password) }
        summary = burst_results.tally.sort_by { |k, _| k }.map { |k, v| "#{k}=#{v}" }.join(' ')
        puts "AUTH burst (x10) => #{summary}"
      end

      sleep 1.0
    end

    puts
    puts "=== Demo finished ==="
    puts "You should see:"
    puts "- BIO rows with SUCCESS (and score/coverage/pairs)"
    puts "- AUTH_FAIL then AUTH_LOCK (423) after repeated wrong passwords"
    puts "- AUTH_RATE (429) after high-frequency attempts"
  end

  private

  def json_headers(extra = {})
    { 'CONTENT_TYPE' => 'application/json' }.merge(extra)
  end

  def parse_json(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    {}
  end

  def expect_status!(expected, context)
    return if last_response.status == expected

    raise "#{context} failed: expected HTTP #{expected}, got #{last_response.status}, body=#{last_response.body}"
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

  def create_and_train_user(prefix:)
    username = "#{prefix}_#{Time.now.to_i}_#{SecureRandom.hex(3)}"
    password = "DemoPass!#{SecureRandom.hex(5)}"

    post '/v1/auth/register', { username: username, password: password }.to_json, json_headers
    expect_status!(200, "register #{username}")

    post '/v1/auth/login', { username: username, password: password }.to_json, json_headers
    expect_status!(200, "auth/login #{username}")
    user_id = parse_json(last_response.body).fetch('user_id').to_i

    post '/v1/train', { user_id: user_id, timings: timing_payload(jitter: 0.0) }.to_json, json_headers
    expect_status!(200, "train user_id=#{user_id}")

    { username: username, user_id: user_id }
  end

  def biometric_login(user_id, jitter: 0.0)
    post '/v1/login', { user_id: user_id, timings: timing_payload(jitter: jitter) }.to_json, json_headers
    expect_status!(200, "biometric login user_id=#{user_id}")
    parse_json(last_response.body).fetch('status')
  rescue => e
    "ERROR(#{e.class})"
  end

  def auth_login(username, password)
    post '/v1/auth/login', { username: username, password: password }.to_json, json_headers
    last_response.status
  rescue
    500
  end
end

LiveDemo2Min.new.run(duration_seconds: 120)
