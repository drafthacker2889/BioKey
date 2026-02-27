require 'json'
require 'securerandom'
require 'time'
require 'rack/test'

ENV['RACK_ENV'] = 'test'
ENV['ADMIN_TOKEN'] ||= 'phase11-admin-token'
ENV['APP_SESSION_SECRET'] ||= '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

require_relative '../backend-server/app'

begin
  $logger.level = Logger::WARN if defined?($logger) && defined?(Logger)
rescue
  nil
end

class HumanSynthetic40
  include Rack::Test::Methods

  BASE_PAIRS = %w[ab bc cd de ef fg].freeze

  def app
    Sinatra::Application
  end

  def run(users_count: 40, train_repetitions: 4, logins_per_user: 24)
    started_at = Time.now
    before = fetch_overview

    users = []
    all_outcomes = Hash.new(0)

    users_count.times do |index|
      profile = build_user_profile(index)
      user = register_and_auth(profile)

      train_repetitions.times do |session_idx|
        train_user(user[:user_id], profile, session_idx)
      end

      outcomes = []
      logins_per_user.times do |attempt_idx|
        outcome = biometric_login(user[:user_id], profile, attempt_idx)
        outcomes << outcome
        all_outcomes[outcome] += 1
      end

      users << {
        username: user[:username],
        user_id: user[:user_id],
        outcomes: outcomes.tally,
        logins: outcomes.length
      }
    end

    after = fetch_overview

    print_report(
      started_at: started_at,
      finished_at: Time.now,
      users: users,
      all_outcomes: all_outcomes,
      before: before,
      after: after
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

  def random_normal(mean:, stddev:)
    u1 = [[rand, 1e-9].max, 1.0 - 1e-9].min
    u2 = rand
    z0 = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
    mean + (z0 * stddev)
  end

  def clamp(value, min, max)
    [[value, min].max, max].min
  end

  def build_user_profile(index)
    username = "human_user_#{Time.now.to_i}_#{index + 1}_#{SecureRandom.hex(2)}"
    password = "HumanPass!#{SecureRandom.hex(5)}"

    base_dwell = random_normal(mean: 103.0, stddev: 12.0)
    base_flight = random_normal(mean: 61.0, stddev: 9.0)

    pair_offsets = {}
    BASE_PAIRS.each do |pair|
      pair_offsets[pair] = {
        dwell: random_normal(mean: 0.0, stddev: 4.5),
        flight: random_normal(mean: 0.0, stddev: 3.8)
      }
    end

    {
      username: username,
      password: password,
      base_dwell: clamp(base_dwell, 75.0, 145.0),
      base_flight: clamp(base_flight, 42.0, 95.0),
      pair_offsets: pair_offsets,
      consistency: clamp(random_normal(mean: 1.0, stddev: 0.15), 0.7, 1.35),
      fatigue_trend: random_normal(mean: 0.0, stddev: 0.012)
    }
  end

  def register_and_auth(profile)
    post '/v1/auth/register', { username: profile[:username], password: profile[:password] }.to_json, json_headers
    expect_status!(200, "register #{profile[:username]}")

    post '/v1/auth/login', { username: profile[:username], password: profile[:password] }.to_json, json_headers
    expect_status!(200, "auth/login #{profile[:username]}")

    body = parse_json!(last_response.body)
    {
      username: profile[:username],
      user_id: body.fetch('user_id').to_i
    }
  end

  def human_timings(profile, attempt_idx:, training: false)
    warmup_factor = training ? 0.985 : 1.0
    fatigue_factor = 1.0 + (profile[:fatigue_trend] * (attempt_idx.to_f / 10.0))

    BASE_PAIRS.each_with_index.map do |pair, pair_idx|
      pair_shift = profile[:pair_offsets][pair]
      rhythmic_wave = Math.sin((attempt_idx + pair_idx) / 3.2) * 1.2
      session_noise_scale = training ? 2.2 : 3.6
      consistency = profile[:consistency]

      dwell = random_normal(
        mean: (profile[:base_dwell] + pair_shift[:dwell] + rhythmic_wave) * warmup_factor * fatigue_factor,
        stddev: session_noise_scale * consistency
      )
      flight = random_normal(
        mean: (profile[:base_flight] + pair_shift[:flight] + rhythmic_wave * 0.6) * warmup_factor * fatigue_factor,
        stddev: (session_noise_scale - 0.6) * consistency
      )

      {
        pair: pair,
        dwell: clamp(dwell, 28.0, 420.0).round(2),
        flight: clamp(flight, 18.0, 360.0).round(2)
      }
    end
  end

  def train_user(user_id, profile, session_idx)
    payload = {
      user_id: user_id,
      timings: human_timings(profile, attempt_idx: session_idx, training: true)
    }

    post '/v1/train', payload.to_json, json_headers
    expect_status!(200, "train user_id=#{user_id}")
  end

  def biometric_login(user_id, profile, attempt_idx)
    payload = {
      user_id: user_id,
      timings: human_timings(profile, attempt_idx: attempt_idx, training: false)
    }

    post '/v1/login', payload.to_json, json_headers
    expect_status!(200, "biometric login user_id=#{user_id}")
    parse_json!(last_response.body).fetch('status')
  end

  def fetch_overview
    get '/admin/api/overview', {}, { 'HTTP_X_ADMIN_TOKEN' => ENV.fetch('ADMIN_TOKEN') }
    expect_status!(200, 'admin overview')
    parse_json!(last_response.body)
  end

  def print_report(started_at:, finished_at:, users:, all_outcomes:, before:, after:)
    duration = (finished_at - started_at).round(2)
    total_logins = users.sum { |u| u[:logins] }
    attempts_delta = after['attempts_24h'].to_i - before['attempts_24h'].to_i

    puts '=== Human-like Synthetic Dataset Generation ==='
    puts "Started:  #{started_at.utc.iso8601}"
    puts "Finished: #{finished_at.utc.iso8601}"
    puts "Duration: #{duration}s"
    puts
    puts "Users created: #{users.length}"
    puts "Biometric logins executed: #{total_logins}"
    puts "Outcome distribution: #{all_outcomes.sort.to_h}"
    puts "Overview attempts_24h delta: #{attempts_delta}"
    puts
    puts 'Sample users:'
    users.first(8).each do |u|
      puts "- #{u[:username]} (id=#{u[:user_id]}): #{u[:outcomes]}"
    end
  end
end

mode = (ARGV[0] || 'default').to_s.downcase

preset = case mode
         when 'light'
           { users_count: 40, train_repetitions: 3, logins_per_user: 15 }
         when 'heavy'
           { users_count: 40, train_repetitions: 6, logins_per_user: 50 }
         else
           { users_count: 40, train_repetitions: 4, logins_per_user: 24 }
         end

users_count = (ARGV[1] || preset[:users_count]).to_i
train_repetitions = (ARGV[2] || preset[:train_repetitions]).to_i
logins_per_user = (ARGV[3] || preset[:logins_per_user]).to_i

puts "[generator] mode=#{mode} users=#{users_count} train_repetitions=#{train_repetitions} logins_per_user=#{logins_per_user}"

HumanSynthetic40.new.run(
  users_count: users_count,
  train_repetitions: train_repetitions,
  logins_per_user: logins_per_user
)
