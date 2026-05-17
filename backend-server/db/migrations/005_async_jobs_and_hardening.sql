CREATE TABLE IF NOT EXISTS async_jobs (
  id VARCHAR(36) PRIMARY KEY,
  job_type VARCHAR(64) NOT NULL,
  status VARCHAR(16) NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  result JSONB,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

ALTER TABLE biometric_attempts
  ALTER COLUMN coverage_ratio TYPE FLOAT USING coverage_ratio::FLOAT,
  ALTER COLUMN matched_pairs TYPE INT USING matched_pairs::INT;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_biometric_attempts_coverage_ratio') THEN
    ALTER TABLE biometric_attempts
      ADD CONSTRAINT chk_biometric_attempts_coverage_ratio
      CHECK (coverage_ratio IS NULL OR (coverage_ratio >= 0 AND coverage_ratio <= 1));
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_biometric_attempts_matched_pairs') THEN
    ALTER TABLE biometric_attempts
      ADD CONSTRAINT chk_biometric_attempts_matched_pairs
      CHECK (matched_pairs IS NULL OR matched_pairs >= 0);
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_typing_capture_event_type') THEN
    ALTER TABLE typing_capture_events
      ADD CONSTRAINT chk_typing_capture_event_type
      CHECK (event_type ~ '^[A-Z0-9_:-]{1,24}$');
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_typing_capture_context') THEN
    ALTER TABLE typing_capture_events
      ADD CONSTRAINT chk_typing_capture_context
      CHECK (context ~ '^[A-Za-z0-9 _:-]{1,64}$');
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_typing_capture_field_name') THEN
    ALTER TABLE typing_capture_events
      ADD CONSTRAINT chk_typing_capture_field_name
      CHECK (field_name ~ '^[A-Za-z0-9 _:-]{1,64}$');
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_biometric_profiles_key_pair') THEN
    ALTER TABLE biometric_profiles
      ADD CONSTRAINT chk_biometric_profiles_key_pair
      CHECK (key_pair ~ '^[A-Za-z0-9:_-]{1,16}$');
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_access_logs_verdict') THEN
    ALTER TABLE access_logs
      ADD CONSTRAINT chk_access_logs_verdict
      CHECK (verdict ~ '^[A-Z_]{2,16}$');
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_user_score_history_outcome') THEN
    ALTER TABLE user_score_history
      ADD CONSTRAINT chk_user_score_history_outcome
      CHECK (outcome IN ('SUCCESS', 'CHALLENGE', 'DENIED', 'ERROR', 'LOW_COVERAGE'));
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_biometric_attempts_user_label_time ON biometric_attempts(user_id, label, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_typing_capture_user_context_time ON typing_capture_events(user_id, context, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_async_jobs_status_time ON async_jobs(status, created_at DESC);
