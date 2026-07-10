-- AlterTable: store before/after prompt text for portal comparison
ALTER TABLE "users" ALTER COLUMN "store_prompts" SET DEFAULT true;

-- Existing users: enable storage so before/after appears (they can opt out in Settings)
UPDATE "users" SET "store_prompts" = true WHERE "retention_policy" <> 'none';

ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "original_text" TEXT;
ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "optimized_text" TEXT;
ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "original_truncated" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "prompt_requests" ADD COLUMN IF NOT EXISTS "optimized_truncated" BOOLEAN NOT NULL DEFAULT false;
