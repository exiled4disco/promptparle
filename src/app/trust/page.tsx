import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import {
  HEURISTIC_CATEGORIES,
  EXPECTATIONS_BLURB,
  DIAL_LEVELS,
} from "@/lib/heuristics-public";
import { INVITE_WHY } from "@/lib/invite-why";
import { ENTITY } from "@/lib/aeo";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: {
    absolute: "Trust & how it works · PromptParle",
  },
  description:
    "How PromptParle handles your data: provider keys and prompt/context stay on your PC. Optimize and model calls run on your machine. Portal for account and license.",
  alternates: { canonical: "/trust" },
  robots: { index: true, follow: true },
};

export default function TrustPage() {
  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="flex-1">
        <section className="container max-w-3xl py-12 md:py-16">
          <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
            Trust
          </p>
          <h1 className="page-title mt-2 !mb-2">
            Your PC runs the work. We handle the license.
          </h1>
          <p className="aeo-direct-answer page-sub !mx-0 !text-left">
            {ENTITY.definition} Desktop client{" "}
            <strong className="text-[var(--text)]">0.25+</strong> optimizes
            context and calls your model on your machine.
          </p>

          <div className="card mt-10 p-5">
            <h2 className="text-lg font-semibold">The data path</h2>
            <p className="aeo-direct-answer mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
              Prompt, context, and provider API keys{" "}
              <strong className="text-[var(--text)]">
                stay on your PC
              </strong>
              . The desktop client optimizes locally, then calls OpenAI / Claude
              / Gemini / Grok with a key stored only on that machine (DPAPI on
              Windows). PromptParle cloud is{" "}
              <strong className="text-[var(--text)]">not</strong> on the model
              path.
            </p>
            <ol className="mt-4 space-y-2 text-sm text-[var(--text-muted)]">
              <li className="flex gap-3">
                <span className="font-bold text-[var(--accent-strong)]">1</span>
                <span>
                  <strong className="text-[var(--text)]">Your PC</strong>, secret gate, dial/profile optimize, drop journal, workspace /
                  Git / SSH tools.
                </span>
              </li>
              <li className="flex gap-3">
                <span className="font-bold text-[var(--accent-strong)]">2</span>
                <span>
                  <strong className="text-[var(--text)]">Your provider</strong>. HTTPS direct from the desktop with your local BYOK key. They
                  bill the tokens.
                </span>
              </li>
              <li className="flex gap-3">
                <span className="font-bold text-[var(--accent-strong)]">3</span>
                <span>
                  <strong className="text-[var(--text)]">PromptParle portal</strong>{" "}, account, plan, desktop license key (<code>pp_live_</code>
                  ), client install package.{" "}
                  <strong className="text-[var(--text)]">
                    No prompt bodies. No provider keys.
                  </strong>
                </span>
              </li>
            </ol>
          </div>

          <div className="card mt-4 p-5">
            <h2 className="text-lg font-semibold">Two different keys</h2>
            <ul className="mt-3 space-y-2 text-sm text-[var(--text-muted)]">
              <li>
                <strong className="text-[var(--text)]">Desktop key</strong>{" "}
                <code className="text-xs">pp_live_…</code>, proves this PC may
                use your license. Stored locally (DPAPI). Hash only on the
                server.
              </li>
              <li>
                <strong className="text-[var(--text)]">Provider keys</strong>{" "}
                <code className="text-xs">sk-…</code> / Claude / Gemini / Grok, stored <strong className="text-[var(--text)]">only on the PC</strong>
                . Set with{" "}
                <code className="text-xs">Set-PromptParleProviderKey</code> or
                Providers in the local UI. Never uploaded to PromptParle.
              </li>
            </ul>
          </div>

          <div className="card mt-4 p-5">
            <h2 className="text-lg font-semibold">Secret gate (on the PC)</h2>
            <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
              Credential-shaped patterns (API keys, tokens, PEM blocks) are
              masked on your machine before any provider call. Default policy is{" "}
              <strong className="text-[var(--text)]">strict</strong>: residual
              high-confidence matches block the send. This is not DLP for IPs or
              hostnames, under local-first those only go to the model provider
              you chose, not to PromptParle.
            </p>
          </div>

          <div className="card mt-4 p-5">
            <h2 className="text-lg font-semibold">Dial 1-5 &amp; savings expectations</h2>
            <p className="aeo-direct-answer mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
              {EXPECTATIONS_BLURB}
            </p>
            <div className="mt-4 overflow-x-auto">
              <table className="w-full min-w-[28rem] text-left text-sm">
                <thead>
                  <tr className="border-b border-[var(--border)] text-[var(--text-dim)]">
                    <th className="py-2 pr-3 font-medium">Dial</th>
                    <th className="py-2 pr-3 font-medium">Name</th>
                    <th className="py-2 pr-3 font-medium">What it does</th>
                    <th className="py-2 font-medium">Typical reduction</th>
                  </tr>
                </thead>
                <tbody className="text-[var(--text-muted)]">
                  {DIAL_LEVELS.map((d) => (
                    <tr
                      key={d.dial}
                      className="border-b border-[var(--border)]/60"
                    >
                      <td className="py-2.5 pr-3 font-semibold text-[var(--accent-strong)]">
                        {d.dial}
                      </td>
                      <td className="py-2.5 pr-3 font-medium text-[var(--text)]">
                        {d.name}
                      </td>
                      <td className="py-2.5 pr-3">{d.summary}</td>
                      <td className="py-2.5 whitespace-nowrap font-semibold text-[var(--text)]">
                        {d.expectPercent}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-3 text-sm text-[var(--text-dim)]">
              Bands assume mixed or noisy work. Clean unique prose often sits
              near zero at any dial, that is correct. Use dial 1-2 when every
              line may matter. The UI can show a drop journal (what was
              collapsed). Provider prompt-prefix caching is complementary for
              stable system/docs, we are not a response cache.
            </p>
            <p className="mt-3 text-sm text-[var(--text-dim)]">
              See{" "}
              <Link
                href="/examples"
                className="font-medium text-[var(--accent-strong)] hover:underline"
              >
                published example packs
              </Link>
              .
            </p>
          </div>

          <div className="mt-10">
            <h2 className="text-lg font-semibold">Heuristic categories (open book)</h2>
            <p className="mt-1 text-sm text-[var(--text-muted)]">
              Deterministic pruning, not an LLM summarizer. Categories below;
              full scoring stays product craft.
            </p>
            <div className="mt-4 grid gap-3">
              {HEURISTIC_CATEGORIES.map((h) => (
                <div key={h.id} className="card p-4">
                  <h3 className="font-semibold text-[var(--text)]">{h.title}</h3>
                  <p className="mt-1 text-sm text-[var(--text-muted)]">
                    {h.summary}
                  </p>
                  <p className="mt-2 text-xs text-[var(--text-dim)]">
                    e.g. {h.examples.join(" · ")}
                  </p>
                </div>
              ))}
            </div>
          </div>

          <div id="invite" className="card mt-10 scroll-mt-28 p-5">
            <h2 className="text-lg font-semibold">{INVITE_WHY.title}</h2>
            <p className="mt-2 text-sm font-medium text-[var(--text)]">
              {INVITE_WHY.lead}
            </p>
            <div className="mt-4 grid gap-3">
              {INVITE_WHY.body.map((b) => (
                <div key={b.title}>
                  <h3 className="text-sm font-semibold text-[var(--accent-strong)]">
                    {b.title}
                  </h3>
                  <p className="mt-1 text-sm text-[var(--text-muted)]">{b.text}</p>
                </div>
              ))}
            </div>
            <p className="mt-4 text-sm text-[var(--text-muted)]">
              {INVITE_WHY.closer}
            </p>
            <Link href="/register" className="btn btn-primary mt-4">
              Create free account
            </Link>
          </div>

          <p className="mt-8 text-center text-sm text-[var(--text-dim)]">
            <Link
              href="/pricing"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              Pricing
            </Link>
            {" · "}
            <Link
              href="/faq"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              FAQ
            </Link>
            {" · "}
            <Link
              href="/install"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              Install
            </Link>
          </p>
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}
