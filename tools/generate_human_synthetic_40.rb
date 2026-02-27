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

  def run(users_count: 40, train_repetitions: 4, logins_per_user: 24, typing_batches_per_user: 10, typing_chars_per_batch: 48)
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

      typing_inserted = generate_typing_capture(
        token: user[:token],
        profile: profile,
        batches: typing_batches_per_user,
        chars_per_batch: typing_chars_per_batch
      )

      users << {
        username: user[:username],
        user_id: user[:user_id],
        outcomes: outcomes.tally,
        logins: outcomes.length,
        typing_events: typing_inserted
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
      user_id: body.fetch('user_id').to_i,
      token: body.fetch('token')
    }
  end

  def random_text(length)
    chars = %w[a s d f g h j k l e r t y u i o n m c v b]
    Array.new(length) { chars.sample }.join
  end

  def context_for_batch(index)
    case index % 3
    when 0 then ['post_composer', 'post_body']
    when 1 then ['comment_box', 'comment_body']
    else ['ambient_capture', 'mixed']
    end
  end

  def build_typing_events(profile, text)
    events = []
    now_ms = (Time.now.to_f * 1000).to_i
    cursor = 0

    text.each_char.with_index do |char, idx|
      dwell = clamp(random_normal(mean: profile[:base_dwell], stddev: 10.5), 24.0, 320.0).round(3)
      flight = if idx.zero?
                 nil
               else
                 clamp(random_normal(mean: profile[:base_flight], stddev: 8.2), 12.0, 260.0).round(3)
               end

      cursor += 1

      events << {
        event_type: 'KEY_DOWN',
        key_value: char,
        key_code: char.ord,
        dwell_ms: nil,
        flight_ms: flight,
        typed_length: cursor,
        cursor_pos: cursor,
        client_ts_ms: now_ms + (idx * 12),
        metadata: { synthetic: true, model: 'human_like_v1' }
      }

      events << {
        event_type: 'KEY_UP',
        key_value: char,
        key_code: char.ord,
        dwell_ms: dwell,
        flight_ms: nil,
        typed_length: cursor,
        cursor_pos: cursor,
        client_ts_ms: now_ms + (idx * 12) + dwell.to_i,
        metadata: { synthetic: true, model: 'human_like_v1' }
      }
    end

    events
  end

  def generate_typing_capture(token:, profile:, batches:, chars_per_batch:)
    inserted_total = 0

    batches.times do |batch_idx|
      context, field_name = context_for_batch(batch_idx)
      text = random_text(chars_per_batch)
      events = build_typing_events(profile, text)

      post '/prototype/api/typing-events',
           {
             context: context,
             field_name: field_name,
             client_session_id: "synthetic_typing_#{SecureRandom.hex(6)}",
             events: events
           }.to_json,
           json_headers('HTTP_AUTHORIZATION' => "Bearer #{token}")

      expect_status!(200, "typing capture batch user_token")
      inserted_total += parse_json!(last_response.body).fetch('inserted').to_i
    end

    inserted_total
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
    puts "Typing capture events inserted: #{users.sum { |u| u[:typing_events].to_i }}"
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
           { users_count: 40, train_repetitions: 3, logins_per_user: 15, typing_batches_per_user: 4, typing_chars_per_batch: 32 }
         when 'heavy'
           { users_count: 40, train_repetitions: 6, logins_per_user: 50, typing_batches_per_user: 14, typing_chars_per_batch: 64 }
         else
           { users_count: 40, train_repetitions: 4, logins_per_user: 24, typing_batches_per_user: 8, typing_chars_per_batch: 48 }
         end

users_count = (ARGV[1] || preset[:users_count]).to_i
train_repetitions = (ARGV[2] || preset[:train_repetitions]).to_i
logins_per_user = (ARGV[3] || preset[:logins_per_user]).to_i
typing_batches_per_user = (ARGV[4] || preset[:typing_batches_per_user]).to_i
typing_chars_per_batch = (ARGV[5] || preset[:typing_chars_per_batch]).to_i

puts "[generator] mode=#{mode} users=#{users_count} train_repetitions=#{train_repetitions} logins_per_user=#{logins_per_user} typing_batches_per_user=#{typing_batches_per_user} typing_chars_per_batch=#{typing_chars_per_batch}"

HumanSynthetic40.new.run(
  users_count: users_count,
  train_repetitions: train_repetitions,
  logins_per_user: logins_per_user,
  typing_batches_per_user: typing_batches_per_user,
  typing_chars_per_batch: typing_chars_per_batch
)
