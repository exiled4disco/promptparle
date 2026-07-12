-- Feedback (bug / suggest) submissions
CREATE TABLE IF NOT EXISTS "feedback_submissions" (
    "id" TEXT NOT NULL,
    "user_id" TEXT,
    "kind" TEXT NOT NULL DEFAULT 'suggest',
    "title" TEXT NOT NULL,
    "body" TEXT NOT NULL,
    "source" TEXT NOT NULL DEFAULT 'portal',
    "email" TEXT,
    "name" TEXT,
    "ip" TEXT,
    "country" TEXT,
    "user_agent" TEXT,
    "status" TEXT NOT NULL DEFAULT 'new',
    "admin_note" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "feedback_submissions_pkey" PRIMARY KEY ("id")
);

CREATE INDEX IF NOT EXISTS "feedback_submissions_status_created_at_idx"
  ON "feedback_submissions"("status", "created_at");
CREATE INDEX IF NOT EXISTS "feedback_submissions_user_id_idx"
  ON "feedback_submissions"("user_id");

ALTER TABLE "feedback_submissions"
  DROP CONSTRAINT IF EXISTS "feedback_submissions_user_id_fkey";
ALTER TABLE "feedback_submissions"
  ADD CONSTRAINT "feedback_submissions_user_id_fkey"
  FOREIGN KEY ("user_id") REFERENCES "users"("id")
  ON DELETE SET NULL ON UPDATE CASCADE;

-- Session title on usage rows; never store prompt bodies by default
ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "session_title" TEXT;
ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "client_session_id" TEXT;

CREATE INDEX IF NOT EXISTS "prompt_requests_user_id_session_title_idx"
  ON "prompt_requests"("user_id", "session_title");

-- Stats-only product default: no prompt/context text storage
ALTER TABLE "users" ALTER COLUMN "store_prompts" SET DEFAULT false;
UPDATE "users" SET "store_prompts" = false;

-- Wipe any previously stored prompt bodies (stats columns untouched)
UPDATE "prompt_requests"
SET
  "original_text" = NULL,
  "optimized_text" = NULL,
  "prompt_preview" = NULL,
  "original_truncated" = false,
  "optimized_truncated" = false;
