-- CreateTable
CREATE TABLE "tool_savings_daily" (
    "id" TEXT NOT NULL,
    "user_id" TEXT NOT NULL,
    "day" TEXT NOT NULL,
    "tool" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "chars_saved" INTEGER NOT NULL DEFAULT 0,
    "occurrences" INTEGER NOT NULL DEFAULT 0,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "tool_savings_daily_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "tool_savings_daily_user_id_idx" ON "tool_savings_daily"("user_id");

-- CreateIndex
CREATE UNIQUE INDEX "tool_savings_daily_user_id_day_tool_provider_key" ON "tool_savings_daily"("user_id", "day", "tool", "provider");

-- AddForeignKey
ALTER TABLE "tool_savings_daily" ADD CONSTRAINT "tool_savings_daily_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
