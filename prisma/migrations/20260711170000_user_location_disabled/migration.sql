-- Capture last seen IP/country; allow admin disable without delete.
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "last_ip" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "last_country" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "last_country_code" TEXT;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "last_ip_at" TIMESTAMP(3);
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "disabled_at" TIMESTAMP(3);
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "disabled_reason" TEXT;

CREATE INDEX IF NOT EXISTS "users_disabled_at_idx" ON "users"("disabled_at");
CREATE INDEX IF NOT EXISTS "users_last_ip_at_idx" ON "users"("last_ip_at");
