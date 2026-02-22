require_relative 'test_helper'
require_relative '../lib/evaluation_service'

class EvaluationServiceTest < Minitest::Test
  def test_compute_metrics_from_rows
    rows = [
      { 'label' => 'GENUINE', 'outcome' => 'SUCCESS' },
      { 'label' => 'GENUINE', 'outcome' => 'DENIED' },
      { 'label' => 'IMPOSTER', 'outcome' => 'SUCCESS' },
      { 'label' => 'IMPOSTER', 'outcome' => 'DENIED' }
    ]

    metrics = EvaluationService.compute_metrics_from_rows(rows)

    assert_equal 2, metrics[:genuine_count]
    assert_equal 2, metrics[:imposter_count]
    assert_equal 1, metrics[:false_accepts]
    assert_equal 1, metrics[:false_rejects]
    assert_in_delta 0.5, metrics[:far], 0.0001
    assert_in_delta 0.5, metrics[:frr], 0.0001
  end
end
