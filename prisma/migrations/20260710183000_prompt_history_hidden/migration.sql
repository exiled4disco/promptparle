-- Soft-hide request history without dropping token stats
ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "history_hidden_at" TIMESTAMP(3);

CREATE INDEX IF NOT EXISTS "prompt_requests_user_id_history_hidden_at_idx"
  ON "prompt_requests"("user_id", "history_hidden_at");
