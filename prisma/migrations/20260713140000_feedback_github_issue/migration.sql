-- Route Bug/Suggest submissions to GitHub Issues: store the created issue number + url.
-- Additive, nullable — safe to apply to a populated table (no backfill needed).
ALTER TABLE "feedback_submissions" ADD COLUMN "github_issue" INTEGER;
ALTER TABLE "feedback_submissions" ADD COLUMN "github_url" TEXT;
