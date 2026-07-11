-- Preferred provider/model + desktop defaults (portal ↔ client sync)
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "preferred_provider" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "preferred_models" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "default_dial" INTEGER NOT NULL DEFAULT 3;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "default_tools_enabled" BOOLEAN NOT NULL DEFAULT true;
