import Link from "next/link";
import { Logo } from "@/components/Logo";
import { CountUpStats } from "@/components/CountUpStats";
import { ComingSoonButton } from "@/components/ComingSoonButton";
import { getSessionUser } from "@/lib/auth";
import { TAGLINE } from "@/lib/constants";

const CAPABILITIES = [
  {
    title: "Context optimization dial",
    body: "Dial 1–5 trades fidelity for savings. Typical balanced runs cut ~45–60% of tokens; max savings can crush 85%+ on noisy logs and docs.",
  },
  {
    title: "Secret masking",
    body: "Scan and mask API keys, tokens, and credentials before context leaves your machine toward a provider.",
  },
  {
    title: "Profiles that match the job",
    body: "General, developer, security-review, log-analysis, documentation, and executive-summary — each tuned for what to keep.",
  },
  {
    title: "Your keys, your spend",
    body: "Bring OpenAI, Claude, Gemini, or Grok. Provider keys stay encrypted in the portal; AI token cost stays on your account.",
  },
  {
    title: "Local desktop chat",
    body: "Free PowerShell UI on 127.0.0.1 — chat history, agents, self-update, and Help — without putting the full chat SPA on the cloud.",
  },
  {
    title: "Workspace · Git · SSH",
    body: "Attach any folder on this PC, clone GitHub repos, and run SSH. Keys and credentials never leave your machine.",
  },
];

const LANDING_STATS = [
  {
    value: 66,
    suffix: "%",
    label: "Example token reduction",
  },
  {
    value: 12220,
    suffix: "+",
    label: "Tokens saved in demo pass",
  },
  {
    value: 4,
    label: "AI providers routed",
  },
  {
    value: 6,
    label: "Optimization profiles",
  },
];

export default async function LandingPage() {
  const user = await getSessionUser();

  return (
    <div className="flex min-h-full flex-col">
      <header className="border-b border-[var(--border)]/80">
        <div className="container flex items-center justify-between py-4">
          <Logo />
          <nav className="flex items-center gap-2">
            {user ? (
              <Link href="/app" className="btn btn-primary">
                Open dashboard
              </Link>
            ) : (
              <>
                <Link href="/login" className="btn btn-ghost">
                  Sign in
                </Link>
                <Link href="/register" className="btn btn-primary">
                  Create free account
                </Link>
              </>
            )}
          </nav>
        </div>
      </header>

      <main className="flex-1">
        {/* Hero — no large logo above the message */}
        <section className="container py-16 md:py-24">
          <div className="mx-auto max-w-3xl text-center">
            <div className="mb-5 inline-flex items-center gap-2 rounded-full border border-[var(--border)] bg-[var(--bg-soft)] px-3 py-1 text-sm text-[var(--text-muted)]">
              <span className="h-1.5 w-1.5 rounded-full bg-[var(--success)]" />
              AI context optimization gateway
            </div>
            <h1 className="text-4xl font-bold tracking-tight md:text-6xl md:leading-[1.08]">
              {TAGLINE}
            </h1>
            <p className="mx-auto mt-5 max-w-2xl text-lg text-[var(--text-muted)] md:text-xl">
              PromptParle sits between your desktop tools and AI providers.
              It thins bloated context, keeps the signal, masks secrets, and
              routes cleaner prompts to OpenAI, Claude, Gemini, and Grok — so
              you pay for less noise.
            </p>
            <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
              {user ? (
                <Link href="/app" className="btn btn-primary">
                  Go to dashboard
                </Link>
              ) : (
                <Link href="/register" className="btn btn-primary">
                  Create free account
                </Link>
              )}
              <ComingSoonButton className="btn btn-secondary">
                Install desktop client
              </ComingSoonButton>
            </div>
            <p className="mt-4 text-sm text-[var(--text-dim)]">
              Registration unlocks encrypted provider keys and a desktop{" "}
              <span className="mono text-[var(--accent-strong)]">pp_live_…</span>{" "}
              API key. Desktop install is coming soon.
            </p>
          </div>

          <CountUpStats stats={LANDING_STATS} />
        </section>

        {/* Capabilities */}
        <section id="capabilities" className="border-t border-[var(--border)] py-16">
          <div className="container">
            <h2 className="page-title text-center">Capabilities</h2>
            <p className="page-sub mx-auto max-w-2xl text-center">
              Built for real workflows: noisy logs, code reviews, security
              packs, docs, and multi-provider routing — with savings you can see.
            </p>
            <div className="mx-auto mt-10 grid max-w-5xl gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {CAPABILITIES.map((item) => (
                <div key={item.title} className="card p-5 text-left">
                  <h3 className="font-semibold text-[var(--text)]">{item.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                    {item.body}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* How it works */}
        <section id="how-it-works" className="border-t border-[var(--border)] py-16">
          <div className="container">
            <h2 className="page-title text-center">The flow</h2>
            <p className="page-sub mx-auto max-w-xl text-center">
              One path from your terminal to any AI provider — with optimization
              and secret masking in the middle.
            </p>
            <div className="mx-auto mt-10 max-w-3xl overflow-hidden rounded-2xl border border-[var(--border)] bg-[var(--bg-elevated)]">
              <pre className="overflow-x-auto p-6 text-sm leading-7 text-[var(--text-muted)] mono">
{`You (local PowerShell UI or script)
  ↓  desktop key pp_live_…
PromptParle API  →  auth · secret scan · optimize (dial 1–5)
  ↓
Your provider     →  OpenAI / Claude / Gemini / Grok
  ↓
Response + original → optimized token savings`}
              </pre>
            </div>

            <div className="mx-auto mt-8 max-w-3xl card p-6">
              <p className="text-sm font-medium text-[var(--text-dim)]">Example savings</p>
              <pre className="mt-3 overflow-x-auto text-sm leading-7 mono text-[#c7d7f5]">
{`Set-PromptParleApiKey -ApiKey "pp_live_xxxxx"

Get-Content .\\firewall-rules.txt -Raw |
  Invoke-PromptParle \`
    -Provider "openai" \`
    -Profile "security-review" \`
    -Prompt "Find risky firewall rules"`}
              </pre>
              <div className="mt-4 rounded-lg border border-[rgba(52,211,153,0.25)] bg-[var(--success-soft)] p-4 text-sm text-[#a7f3d0]">
                Original tokens: 18,450 → Optimized: 6,230 · Reduction:{" "}
                <strong>66%</strong> · Saved <strong>12,220</strong> tokens
              </div>
            </div>
          </div>
        </section>

        {/* Registration path + desktop coming soon */}
        <section id="get-started" className="border-t border-[var(--border)] py-16">
          <div className="container">
            <h2 className="page-title text-center">Get started</h2>
            <p className="page-sub mx-auto max-w-xl text-center">
              Create a free account now. Desktop install is coming soon —
              register so you&apos;re ready when it ships.
            </p>

            <div className="mx-auto mt-10 grid max-w-4xl gap-4 md:grid-cols-2">
              <div className="card flex flex-col p-6">
                <div className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
                  Available now · Portal
                </div>
                <h3 className="mt-2 text-lg font-semibold">Create free account</h3>
                <ul className="mt-4 flex-1 space-y-2 text-sm text-[var(--text-muted)]">
                  <li>• Register and verify email</li>
                  <li>• Add OpenAI / Claude / Gemini / Grok keys (encrypted)</li>
                  <li>• Create a desktop API key (<span className="mono">pp_live_…</span>)</li>
                  <li>• Track usage and token savings</li>
                </ul>
                <Link
                  href={user ? "/app" : "/register"}
                  className="btn btn-primary mt-6 w-full"
                >
                  {user ? "Open dashboard" : "Create free account"}
                </Link>
              </div>

              <div className="card flex flex-col p-6">
                <div className="text-xs font-semibold uppercase tracking-wide text-[var(--warning)]">
                  Coming soon · Desktop
                </div>
                <h3 className="mt-2 text-lg font-semibold">Install desktop client</h3>
                <p className="mt-3 text-sm text-[var(--text-muted)]">
                  Free local PowerShell chat on your PC — dial, agents, workspace,
                  Git, and SSH — without putting the full chat SPA in the cloud.
                </p>
                <ul className="mt-4 flex-1 space-y-2 text-sm text-[var(--text-muted)]">
                  <li>• Local chat UI on 127.0.0.1</li>
                  <li>• Chat history, agents, dial, workspace / SSH / Git</li>
                  <li>• Self-update when new builds ship</li>
                </ul>
                <ComingSoonButton className="btn btn-secondary mt-6 w-full">
                  Install desktop client
                </ComingSoonButton>
              </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="border-t border-[var(--border)] py-8">
        <div className="container flex flex-col items-center justify-between gap-3 text-sm text-[var(--text-dim)] md:flex-row">
          <Logo size="sm" />
          <p>promptparle.com · {TAGLINE}</p>
        </div>
      </footer>
    </div>
  );
}
