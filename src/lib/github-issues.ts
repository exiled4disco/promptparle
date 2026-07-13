/**
 * Route portal/client Bug & Suggest submissions to GitHub Issues.
 *
 * The GitHub repo is the source of truth for bugs; the DB row is the durable record.
 * This is BEST-EFFORT: a GitHub failure must never fail a feedback submission. If the
 * token/repo env is missing, this is a no-op (submissions still land in the DB and email).
 *
 * Env:
 *   GITHUB_TOKEN        fine-grained PAT with Issues: read/write on the repo (required)
 *   GITHUB_ISSUES_REPO  "owner/name" of the SoT repo (default: exiled4disco/promptparle_repo)
 */

export type FeedbackKindForIssue = "bug" | "suggest" | "contact";

function issuesRepo(): string {
  return (process.env.GITHUB_ISSUES_REPO || "exiled4disco/promptparle_repo").trim();
}

export function isGithubIssuesConfigured(): boolean {
  return !!(process.env.GITHUB_TOKEN && process.env.GITHUB_TOKEN.trim());
}

/** Labels: always from-portal (submission origin) + the kind. */
function labelsFor(kind: FeedbackKindForIssue): string[] {
  const base = ["from-portal"];
  if (kind === "bug") base.push("bug", "P2");
  else if (kind === "suggest") base.push("feature");
  else base.push("question");
  return base;
}

/**
 * Create a GitHub issue for a feedback submission. Returns { number, url } on success,
 * or null on any failure/misconfiguration (caller keeps the DB row regardless).
 */
export async function createGithubIssueForFeedback(opts: {
  id: string;
  kind: FeedbackKindForIssue;
  title: string;
  body: string;
  source: string;
  email?: string | null;
  name?: string | null;
}): Promise<{ number: number; url: string } | null> {
  if (!isGithubIssuesConfigured()) return null;
  const repo = issuesRepo();
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) return null;

  // Metadata footer — origin/submitter/DB id for traceability. No secrets.
  const who = opts.name || opts.email || "anonymous";
  const footer = [
    "",
    "---",
    `_Submitted via **${opts.source}** by ${who}_`,
    `_Feedback id: \`${opts.id}\`_`,
  ].join("\n");
  const title = `[${opts.kind}] ${opts.title}`.slice(0, 250);
  const body = `${opts.body}\n${footer}`.slice(0, 60000);

  try {
    const res = await fetch(`https://api.github.com/repos/${repo}/issues`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.GITHUB_TOKEN!.trim()}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
        "User-Agent": "promptparle-portal",
      },
      body: JSON.stringify({ title, body, labels: labelsFor(opts.kind) }),
      // Never hang a request on GitHub.
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) {
      console.error("github issue create failed", res.status, await res.text().catch(() => ""));
      return null;
    }
    const data = (await res.json()) as { number?: number; html_url?: string };
    if (typeof data.number !== "number" || !data.html_url) return null;
    return { number: data.number, url: data.html_url };
  } catch (err) {
    console.error("github issue create error", err);
    return null;
  }
}
