-- OAuth-only users may have no password
ALTER TABLE "users" ALTER COLUMN "password_hash" DROP NOT NULL;

-- Linked identity providers
CREATE TABLE "oauth_accounts" (
    "id" TEXT NOT NULL,
    "user_id" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "provider_user_id" TEXT NOT NULL,
    "email" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "oauth_accounts_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "oauth_accounts_provider_provider_user_id_key" ON "oauth_accounts"("provider", "provider_user_id");
CREATE INDEX "oauth_accounts_user_id_idx" ON "oauth_accounts"("user_id");

ALTER TABLE "oauth_accounts" ADD CONSTRAINT "oauth_accounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- Login lockout
CREATE TABLE "login_attempts" (
    "id" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "fails" INTEGER NOT NULL DEFAULT 0,
    "locked_until" TIMESTAMP(3),
    "updated_at" TIMESTAMP(3) NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "login_attempts_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "login_attempts_key_key" ON "login_attempts"("key");

-- Audit trail
CREATE TABLE "audit_events" (
    "id" TEXT NOT NULL,
    "user_id" TEXT,
    "action" TEXT NOT NULL,
    "ip" TEXT,
    "meta" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_events_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "audit_events_user_id_created_at_idx" ON "audit_events"("user_id", "created_at");
CREATE INDEX "audit_events_action_created_at_idx" ON "audit_events"("action", "created_at");
