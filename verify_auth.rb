require 'minitest/autorun'
require 'mocha/minitest'
require 'json'
require_relative 'backend-server/lib/auth_service'

# Mock the DB constant
class MockDB
  def exec_params(query, params)
    # Return a dummy result object
  end
end

DB = MockDB.new

class TestAuthService < Minitest::Test
  def setup
    # Reset mocks
  end

  def test_verify_login_success
    user_id = 1
    attempt_data = [
      { 'pair' => 'ab', 'dwell' => 100, 'flight' => 50 },
      { 'pair' => 'bc', 'dwell' => 110, 'flight' => 60 }
    ]

    # Mock DB response for profile fetch
    mock_result = mock()
    mock_result.stubs(:ntuples).returns(2)
    mock_result.stubs(:each).yields({
      'key_pair' => 'ab', 'avg_dwell_time' => '100', 'avg_flight_time' => '50', 'sample_count' => '10'
    }).yields({
      'key_pair' => 'bc', 'avg_dwell_time' => '110', 'avg_flight_time' => '60', 'sample_count' => '10'
    })
    
    DB.expects(:exec_params).with(regexp_matches(/SELECT key_pair/), [user_id]).returns(mock_result)

    # Mock MathEngine to return a perfect match
    MathEngine.expects(:get_score).returns(5.0) # < 10.0 is perfect match

    # Mock DB update
    DB.expects(:exec_params).with(regexp_matches(/UPDATE biometric_profiles/), anything).twice

    result = AuthService.verify_login(user_id, attempt_data)
    
    assert_equal "SUCCESS", result[:status]
    assert_equal 5.0, result[:score]
  end

  def test_verify_login_imposter
    user_id = 1
    attempt_data = [
      { 'pair' => 'ab', 'dwell' => 200, 'flight' => 150 } # Very different
    ]

    mock_result = mock()
    mock_result.stubs(:ntuples).returns(1)
    mock_result.stubs(:each).yields({
      'key_pair' => 'ab', 'avg_dwell_time' => '100', 'avg_flight_time' => '50', 'sample_count' => '10'
    })

    DB.expects(:exec_params).with(regexp_matches(/SELECT key_pair/), [user_id]).returns(mock_result)
    MathEngine.expects(:get_score).returns(50.0) # > 20.0 is imposter

    # Should NOT update profile
    DB.expects(:exec_params).with(regexp_matches(/UPDATE biometric_profiles/), anything).never

    result = AuthService.verify_login(user_id, attempt_data)
    
    assert_equal "DENIED", result[:status]
  end
end
