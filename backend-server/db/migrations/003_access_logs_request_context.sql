-- Add request context to access logs for better dashboard visibility.

ALTER TABLE access_logs
  ADD COLUMN IF NOT EXISTS ip_address TEXT;

ALTER TABLE access_logs
  ADD COLUMN IF NOT EXISTS request_id VARCHAR(64);

CREATE INDEX IF NOT EXISTS idx_access_logs_verdict_time ON access_logs(verdict, attempted_at DESC);
