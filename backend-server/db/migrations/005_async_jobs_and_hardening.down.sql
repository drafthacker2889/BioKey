DROP INDEX IF EXISTS idx_async_jobs_status_time;
DROP INDEX IF EXISTS idx_typing_capture_user_context_time;
DROP INDEX IF EXISTS idx_biometric_attempts_user_label_time;

ALTER TABLE user_score_history DROP CONSTRAINT IF EXISTS chk_user_score_history_outcome;
ALTER TABLE access_logs DROP CONSTRAINT IF EXISTS chk_access_logs_verdict;
ALTER TABLE biometric_profiles DROP CONSTRAINT IF EXISTS chk_biometric_profiles_key_pair;
ALTER TABLE typing_capture_events DROP CONSTRAINT IF EXISTS chk_typing_capture_field_name;
ALTER TABLE typing_capture_events DROP CONSTRAINT IF EXISTS chk_typing_capture_context;
ALTER TABLE typing_capture_events DROP CONSTRAINT IF EXISTS chk_typing_capture_event_type;
ALTER TABLE biometric_attempts DROP CONSTRAINT IF EXISTS chk_biometric_attempts_matched_pairs;
ALTER TABLE biometric_attempts DROP CONSTRAINT IF EXISTS chk_biometric_attempts_coverage_ratio;

DROP TABLE IF EXISTS async_jobs;