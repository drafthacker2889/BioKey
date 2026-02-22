require_relative 'test_helper'

DB = FakeDB.new unless defined?(DB)
require_relative '../lib/auth_service'

class AuthServiceTest < Minitest::Test
  def setup
    DB.set_profiles(1, [])
  end

  def test_normalize_attempt_timing_supports_hash_and_numeric
    hash_timing = AuthService.normalize_attempt_timing({ 'pair' => 'ab', 'dwell' => 100, 'flight' => 40 }, 0)
    numeric_timing = AuthService.normalize_attempt_timing(120, 3)

    assert_equal('ab', hash_timing['pair'])
    assert_equal(100.0, hash_timing['dwell'])
    assert_equal('k3', numeric_timing['pair'])
    assert_equal(120.0, numeric_timing['flight'])
  end

  def test_verify_login_returns_error_when_profile_missing
    result = AuthService.verify_login(1, [{ 'pair' => 'ab', 'dwell' => 100, 'flight' => 50 }])

    assert_equal('ERROR', result[:status])
    assert_match(/No profile found/, result[:message])
  end

  def test_verify_login_returns_error_on_low_coverage
    DB.set_profiles(1, [
      {
        'key_pair' => 'ab',
        'avg_dwell_time' => '100',
        'avg_flight_time' => '50',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      }
    ])

    AuthService.stub(:record_score, nil) do
      result = AuthService.verify_login(1, [{ 'pair' => 'ab', 'dwell' => 100, 'flight' => 50 }])
      assert_equal('ERROR', result[:status])
      assert_match(/Insufficient matched pairs/, result[:message])
    end
  end

  def test_verify_login_success_flow_returns_thresholds
    DB.set_profiles(1, [
      {
        'key_pair' => 'ab',
        'avg_dwell_time' => '100',
        'avg_flight_time' => '50',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      },
      {
        'key_pair' => 'bc',
        'avg_dwell_time' => '101',
        'avg_flight_time' => '51',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      },
      {
        'key_pair' => 'cd',
        'avg_dwell_time' => '102',
        'avg_flight_time' => '52',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      },
      {
        'key_pair' => 'de',
        'avg_dwell_time' => '103',
        'avg_flight_time' => '53',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      },
      {
        'key_pair' => 'ef',
        'avg_dwell_time' => '104',
        'avg_flight_time' => '54',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      },
      {
        'key_pair' => 'fg',
        'avg_dwell_time' => '105',
        'avg_flight_time' => '55',
        'std_dev_dwell' => '20',
        'std_dev_flight' => '20',
        'sample_count' => '12',
        'm2_dwell' => '0',
        'm2_flight' => '0'
      }
    ])

    attempt = [
      { 'pair' => 'ab', 'dwell' => 100, 'flight' => 50 },
      { 'pair' => 'bc', 'dwell' => 101, 'flight' => 51 },
      { 'pair' => 'cd', 'dwell' => 102, 'flight' => 52 },
      { 'pair' => 'de', 'dwell' => 103, 'flight' => 53 },
      { 'pair' => 'ef', 'dwell' => 104, 'flight' => 54 },
      { 'pair' => 'fg', 'dwell' => 105, 'flight' => 55 }
    ]

    AuthService.stub(:weighted_variance_aware_score, 1.1) do
      AuthService.stub(:calibrated_thresholds_for_user, { success: 1.5, challenge: 2.2 }) do
        AuthService.stub(:record_score, nil) do
          AuthService.stub(:update_profile, nil) do
            result = AuthService.verify_login(1, attempt)
            assert_equal('SUCCESS', result[:status])
            assert_equal(6, result[:matched_pairs])
            assert_in_delta(1.0, result[:coverage_ratio], 0.001)
            assert_in_delta(1.5, result[:success_threshold], 0.0001)
          end
        end
      end
    end
  end
end
