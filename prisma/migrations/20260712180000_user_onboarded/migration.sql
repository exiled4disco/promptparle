-- Track whether the user has completed/skipped the setup walkthrough.
ALTER TABLE "users" ADD COLUMN "onboarded_at" TIMESTAMP(3);

-- Existing accounts predate the wizard — treat them as already onboarded so
-- they aren't redirected into it.
UPDATE "users" SET "onboarded_at" = NOW() WHERE "onboarded_at" IS NULL;
