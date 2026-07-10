-- Desktop project-connection feature flags + concurrent client seats
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "feat_project_pc" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "feat_project_ssh" BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "feat_project_git" BOOLEAN NOT NULL DEFAULT true;

CREATE TABLE IF NOT EXISTS "desktop_clients" (
    "id" TEXT NOT NULL,
    "user_id" TEXT NOT NULL,
    "client_id" TEXT NOT NULL,
    "hostname" TEXT,
    "platform" TEXT,
    "app_version" TEXT,
    "last_seen_at" TIMESTAMP(3) NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "desktop_clients_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "desktop_clients_user_id_client_id_key"
  ON "desktop_clients"("user_id", "client_id");

CREATE INDEX IF NOT EXISTS "desktop_clients_user_id_last_seen_at_idx"
  ON "desktop_clients"("user_id", "last_seen_at");

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'desktop_clients_user_id_fkey'
  ) THEN
    ALTER TABLE "desktop_clients"
      ADD CONSTRAINT "desktop_clients_user_id_fkey"
      FOREIGN KEY ("user_id") REFERENCES "users"("id")
      ON DELETE CASCADE ON UPDATE CASCADE;
  END IF;
END $$;
