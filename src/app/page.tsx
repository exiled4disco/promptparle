import Link from "next/link";
import { Logo } from "@/components/Logo";
import { getSessionUser } from "@/lib/auth";
import { TAGLINE } from "@/lib/constants";

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
                  Get started
                </Link>
              </>
            )}
          </nav>
        </div>
      </header>

      <main className="flex-1">
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
              It thins bloated context, keeps the signal, and routes cleaner
              prompts to OpenAI, Claude, and more — so you pay for less noise.
            </p>
            <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
              <Link href={user ? "/app" : "/register"} className="btn btn-primary">
                {user ? "Go to dashboard" : "Create free account"}
              </Link>
              <a href="#how-it-works" className="btn btn-secondary">
                How it works
              </a>
            </div>
          </div>

          <div className="mx-auto mt-14 grid max-w-4xl gap-4 md:grid-cols-3">
            {[
              {
                title: "Optimize before send",
                body: "Strip filler, dedupe logs, preserve errors, code, and security indicators.",
              },
              {
                title: "Your provider keys",
                body: "Store OpenAI and Claude keys encrypted. Use one PromptParle desktop key locally.",
              },
              {
                title: "Desktop-first",
                body: "PowerShell and VS Code clients talk to one API. Portal manages accounts and usage.",
              },
            ].map((item) => (
              <div key={item.title} className="card p-5 text-left">
                <h3 className="font-semibold">{item.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                  {item.body}
                </p>
              </div>
            ))}
          </div>
        </section>

        <section id="how-it-works" className="border-t border-[var(--border)] py-16">
          <div className="container">
            <h2 className="page-title text-center">The flow</h2>
            <p className="page-sub mx-auto max-w-xl text-center">
              One path from your terminal to any AI provider — with optimization in the middle.
            </p>
            <div className="mx-auto mt-10 max-w-3xl overflow-hidden rounded-2xl border border-[var(--border)] bg-[var(--bg-elevated)]">
              <pre className="overflow-x-auto p-6 text-sm leading-7 text-[var(--text-muted)] mono">
{`User
  ↓
PowerShell / VS Code
  ↓
PromptParle API  →  auth · policy · secret scan · optimize
  ↓
Provider adapter  →  OpenAI / Claude / Gemini / Grok
  ↓
Response + token reduction metadata`}
              </pre>
            </div>

            <div className="mx-auto mt-8 max-w-3xl card p-6">
              <p className="text-sm font-medium text-[var(--text-dim)]">Example</p>
              <pre className="mt-3 overflow-x-auto text-sm leading-7 mono text-[#c7d7f5]">
{`Set-PromptParleApiKey -ApiKey "pp_live_xxxxx"

Get-Content .\\firewall-rules.txt | Invoke-PromptParle \`
  -Provider "openai" \`
  -Profile "security-review" \`
  -Prompt "Find risky firewall rules"`}
              </pre>
              <div className="mt-4 rounded-lg border border-[rgba(52,211,153,0.25)] bg-[var(--success-soft)] p-4 text-sm text-[#a7f3d0]">
                Original tokens: 18,450 → Optimized: 6,230 · Reduction: 66%
              </div>
            </div>
          </div>
        </section>

        <section className="border-t border-[var(--border)] py-16">
          <div className="container grid gap-6 md:grid-cols-2">
            <div className="card p-6">
              <h3 className="text-lg font-semibold">Portal (this product surface)</h3>
              <ul className="mt-4 space-y-2 text-sm text-[var(--text-muted)]">
                <li>• Account registration and login</li>
                <li>• Encrypted AI provider key storage</li>
                <li>• PromptParle desktop API key generation</li>
                <li>• Usage history and token savings</li>
                <li>• Retention and prompt storage controls</li>
              </ul>
            </div>
            <div className="card p-6">
              <h3 className="text-lg font-semibold">Coming next</h3>
              <ul className="mt-4 space-y-2 text-sm text-[var(--text-muted)]">
                <li>• PowerShell module (Invoke-PromptParle)</li>
                <li>• Context optimizer with profiles</li>
                <li>• OpenAI + Claude live routing</li>
                <li>• VS Code extension</li>
                <li>• Gemini and Grok adapters</li>
              </ul>
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
