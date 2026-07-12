-- Admin flag
ALTER TABLE "users" ADD COLUMN "is_admin" BOOLEAN NOT NULL DEFAULT false;

-- Promote the founder/admin account out-of-band (do NOT hardcode an email here).
-- After the first account is created, grant admin manually, e.g.:
--   UPDATE "users" SET "is_admin" = true WHERE "email" = '<your-admin-email>';
-- or set it via your own seed/ops script.

-- Invitations
CREATE TABLE "invitations" (
    "id" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "code" TEXT NOT NULL,
    "token_hash" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'pending',
    "invited_by_id" TEXT NOT NULL,
    "accepted_user_id" TEXT,
    "note" TEXT,
    "expires_at" TIMESTAMP(3) NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "accepted_at" TIMESTAMP(3),
    "redeemed_at" TIMESTAMP(3),
    "revoked_at" TIMESTAMP(3),

    CONSTRAINT "invitations_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "invitations_code_key" ON "invitations"("code");
CREATE UNIQUE INDEX "invitations_token_hash_key" ON "invitations"("token_hash");
CREATE UNIQUE INDEX "invitations_accepted_user_id_key" ON "invitations"("accepted_user_id");
CREATE INDEX "invitations_email_idx" ON "invitations"("email");
CREATE INDEX "invitations_status_created_at_idx" ON "invitations"("status", "created_at");

ALTER TABLE "invitations" ADD CONSTRAINT "invitations_invited_by_id_fkey" FOREIGN KEY ("invited_by_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "invitations" ADD CONSTRAINT "invitations_accepted_user_id_fkey" FOREIGN KEY ("accepted_user_id") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;
