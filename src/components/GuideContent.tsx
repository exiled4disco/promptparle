import Link from "next/link";

function Section({
  id,
  title,
  children,
}: {
  id: string;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section id={id} className="grid gap-3 scroll-mt-24">
      <h2 className="border-b border-[var(--border)] pb-2 text-xl font-semibold">
        {title}
      </h2>
      <div className="grid gap-3 text-[var(--text-muted)] leading-relaxed">
        {children}
      </div>
    </section>
  );
}

/**
 * The User guide body, shared by the public `/guide` page (in marketing chrome)
 * and the in-portal `/app/guide` page (in portal chrome). Single source so the
 * two never drift. `showHeader` toggles the big page header (the portal page
 * uses PageHeader instead).
 */
export function GuideContent({ showHeader = true }: { showHeader?: boolean }) {
  return (
    <div className="mx-auto grid max-w-3xl gap-10">
      {showHeader && (
        <header className="grid gap-2">
          <h1 className="page-title !mb-0">User guide</h1>
          <p className="page-sub !mx-0 !mt-0 max-w-2xl text-sm">
            PromptParle is free for everyone. Optimization and provider calls run
            on your own PC with your own provider keys (BYOK); the portal handles
            licensing, stats, and support only — it never stores or proxies your
            prompts or keys.
          </p>
        </header>
      )}

      <Section id="install" title="1. Install the desktop client (Windows)">
        <p>
          You need Git for Windows, PowerShell 5.1+, and a free{" "}
          <Link
            href="/register"
            className="text-[var(--accent-strong)] underline underline-offset-2"
          >
            promptparle.com
          </Link>{" "}
          account. The desktop client is a free local PowerShell chat UI —
          optimization and model calls stay on your machine.
        </p>
        <p>Install the module from PowerShell:</p>
        <pre className="overflow-x-auto rounded-lg border border-[var(--border)] bg-[rgba(0,0,0,0.35)] p-4 text-sm">
          <code>irm https://promptparle.com/install.ps1 | iex</code>
        </pre>
        <p>
          Paste your <code>pp_live_…</code> license key when prompted, then start
          the client:
        </p>
        <pre className="overflow-x-auto rounded-lg border border-[var(--border)] bg-[rgba(0,0,0,0.35)] p-4 text-sm">
          <code>pp</code>
        </pre>
        <p>
          Your browser opens the local UI at{" "}
          <code>http://127.0.0.1:7788/</code> (local only, bound to 127.0.0.1
          with a per-run token). Leave the PowerShell window open.
        </p>
      </Section>

      <Section id="account" title="2. Account + a license key per desktop">
        <p>
          Create a free account and sign in with Google, GitHub, or email (new
          accounts verify email first). In the portal, open{" "}
          <strong>Licenses</strong>, create a desktop license key, and copy the{" "}
          <code>pp_live_…</code> value — it is shown once.
        </p>
        <p>
          <strong>Each desktop needs its own <code>pp_live_</code> key.</strong>{" "}
          The key is license/entitlements only; the server stores a hash, not the
          key. It is not a place to put provider keys.
        </p>
      </Section>

      <Section id="byok" title="3. Bring your own keys (BYOK)">
        <p>
          Add your OpenAI, Claude, Gemini, or Grok keys on the PC — never in the
          portal. From the local UI: <strong>⋯ → Providers</strong> → paste key →{" "}
          <strong>Save on this PC</strong>. Or from PowerShell:
        </p>
        <pre className="overflow-x-auto rounded-lg border border-[var(--border)] bg-[rgba(0,0,0,0.35)] p-4 text-sm">
          <code>{`Set-PromptParleProviderKey -Provider openai -ApiKey '…'`}</code>
        </pre>
        <p>
          Keys are stored locally (DPAPI on Windows) and never uploaded. A secret
          gate masks credential-shaped patterns on the PC before any provider
          call.
        </p>
      </Section>

      <Section id="optimize" title="4. Optimize & chat">
        <p>
          PromptParle thins bloated context and keeps the signal, then routes the
          cleaner prompt to your chosen provider. Locally it applies an optimize
          pass (dial / profile / drop journal) before the provider call, so you
          send fewer tokens for the same intent.
        </p>
        <p>
          Chat in the local browser UI or from PowerShell. You pick the provider
          and model; the request goes straight from your PC to that provider with
          your key.
        </p>
      </Section>

      <Section id="savings" title="5. The savings meter">
        <p>
          Every request returns honest savings metadata on the PC. For a
          single-shot optimize you see a before → after readout — the original
          prompt size versus the optimized size actually sent. For agent-style
          work you see the build cost readout for that run. These measure like
          against like; the portal <strong>Stats</strong> page aggregates your
          cumulative token savings over time.
        </p>
      </Section>

      <Section id="privacy" title="Local-first privacy">
        <p>
          Optimization, provider keys, and model calls all run on your PC. The
          portal is separate and rarely contacted — it handles your account,
          per-desktop <code>pp_live_</code> license key, and usage stats only. It
          stores no prompt bodies and no provider keys.
        </p>
      </Section>

      <Section id="update" title="Keep it current">
        <p>Update from PowerShell:</p>
        <pre className="overflow-x-auto rounded-lg border border-[var(--border)] bg-[rgba(0,0,0,0.35)] p-4 text-sm">
          <code>{`Update-PromptParleClient -Force\npp`}</code>
        </pre>
        <p>
          Or click <strong>Update</strong> in the local UI (it turns red when a
          newer version is available). See the{" "}
          <Link
            href="/changelog"
            className="text-[var(--accent-strong)] underline underline-offset-2"
          >
            change control
          </Link>{" "}
          page for release history.
        </p>
      </Section>
    </div>
  );
}
