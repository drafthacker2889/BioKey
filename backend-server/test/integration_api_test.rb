require 'minitest/autorun'
require 'rack/test'
require 'json'

ENV['RACK_ENV'] = 'test'
ENV['ADMIN_TOKEN'] ||= 'ci-admin-token'
ENV['APP_SESSION_SECRET'] ||= '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

require_relative '../app'

class IntegrationApiTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  def setup
    @username = "it_user_#{Time.now.to_i}_#{rand(1000)}"
    @password = 'integration_password_123'

    DB.exec_params('DELETE FROM user_sessions WHERE user_id IN (SELECT id FROM users WHERE username = $1)', [@username])
    DB.exec_params('DELETE FROM biometric_attempts WHERE user_id IN (SELECT id FROM users WHERE username = $1)', [@username])
    DB.exec_params('DELETE FROM user_score_history WHERE user_id IN (SELECT id FROM users WHERE username = $1)', [@username])
    DB.exec_params('DELETE FROM user_score_thresholds WHERE user_id IN (SELECT id FROM users WHERE username = $1)', [@username])
    DB.exec_params('DELETE FROM biometric_profiles WHERE user_id IN (SELECT id FROM users WHERE username = $1)', [@username])
    DB.exec_params('DELETE FROM access_logs WHERE user_id IN (SELECT id FROM users WHERE username = $1)', [@username])
    DB.exec_params('DELETE FROM users WHERE username = $1', [@username])
  end

  def test_auth_train_login_and_admin_label_flow
    post '/v1/auth/register', { username: @username, password: @password }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status

    post '/v1/auth/login', { username: @username, password: @password }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    login_body = parse_json(last_response.body)

    token = login_body.fetch('token')
    user_id = login_body.fetch('user_id').to_i

    get '/v1/auth/profile', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
    assert_equal 200, last_response.status

    timings = [
      { pair: 'ab', dwell: 100, flight: 60 },
      { pair: 'bc', dwell: 110, flight: 62 },
      { pair: 'cd', dwell: 95, flight: 59 },
      { pair: 'de', dwell: 105, flight: 61 },
      { pair: 'ef', dwell: 102, flight: 58 },
      { pair: 'fg', dwell: 108, flight: 63 }
    ]

    post '/v1/train', { user_id: user_id, timings: timings }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status

    post '/v1/login', { user_id: user_id, timings: timings }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
    bio_body = parse_json(last_response.body)
    assert_includes %w[SUCCESS CHALLENGE DENIED], bio_body['status']

    get '/admin/api/feed?limit=5', {}, { 'HTTP_X_ADMIN_TOKEN' => ENV.fetch('ADMIN_TOKEN') }
    assert_equal 200, last_response.status
    feed_body = parse_json(last_response.body)
    attempts = feed_body['attempts'] || []
    refute_empty attempts

    attempt_id = attempts.first.fetch('id')

    post "/admin/api/attempt/#{attempt_id}/label", { label: 'GENUINE' }.to_json,
         { 'CONTENT_TYPE' => 'application/json', 'HTTP_X_ADMIN_TOKEN' => ENV.fetch('ADMIN_TOKEN') }
    assert_equal 200, last_response.status
    label_body = parse_json(last_response.body)
    assert_equal 'SUCCESS', label_body['status']
    assert_equal 'GENUINE', label_body['label']
  end

  private

  def parse_json(payload)
    JSON.parse(payload)
  end
end
