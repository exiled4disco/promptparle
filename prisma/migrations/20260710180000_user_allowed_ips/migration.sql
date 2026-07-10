-- Optional per-user API IP/CIDR allowlist (desktop API keys only)
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "allowed_ips" TEXT;
