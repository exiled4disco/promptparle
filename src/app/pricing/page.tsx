import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { PUBLIC_PLANS, SUPPORT } from "@/lib/pricing";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: {
    absolute: "Free. Pay what you can · PromptParle (promptparle.com)",
  },
  description:
    "PromptParle is free for everyone — no paid tier, no paywall. Optimization and provider calls run on your own PC with your own keys (BYOK). Support the project with an optional pay-what-you-can donation.",
  alternates: { canonical: "/pricing" },
  robots: { index: true, follow: true },
  openGraph: {
    title: "PromptParle is free",
    description:
      "Everything is free — no paid tier. Prompts and provider keys never leave your PC. Optional pay-what-you-can support keeps the project maintained.",
    url: "/pricing",
  },
};

export default function PricingPage() {
  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="flex-1">
        <section className="container max-w-5xl py-12 md:py-16">
          <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
            Pricing
          </p>
          <h1 className="page-title mt-2 !mb-2">Free. Pay what you can.</h1>
          <p className="aeo-direct-answer page-sub !mx-0 max-w-2xl !text-left">
            PromptParle is{" "}
            <strong className="text-[var(--text)]">free for everyone</strong> — no
            paid tier, no paywall, no feature locks. Optimization and provider
            calls run on your own PC with your own keys (BYOK), so there is no
            server on the prompt path and nothing to charge you for.
          </p>
          <p className="mt-3 text-sm text-[var(--text-dim)]">
            Your AI provider still bills its own tokens on your BYOK keys — we
            just help those tokens work harder. Prompts and provider keys never
            leave your PC.
          </p>

          {(() => {
            const plan = PUBLIC_PLANS[0];
            return (
              <div className="mt-10 grid gap-4 lg:grid-cols-2">
                <div className="card flex flex-col border-[var(--accent)]/50 p-6 ring-1 ring-[var(--accent)]/30">
                  <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
                    Everything, free
                  </div>
                  <h2 className="text-xl font-bold">{plan.name}</h2>
                  <p className="mt-1 text-sm text-[var(--text-muted)]">
                    {plan.tagline}
                  </p>
                  <div className="mt-4 flex items-baseline gap-1">
                    <span className="text-4xl font-extrabold tracking-tight">
                      $0
                    </span>
                    <span className="text-sm text-[var(--text-dim)]">
                      forever
                    </span>
                  </div>
                  <ul className="mt-5 flex-1 space-y-2 text-sm text-[var(--text-muted)]">
                    {plan.features.map((f) => (
                      <li key={f} className="flex gap-2">
                        <span className="text-[var(--success)]" aria-hidden>
                          ✓
                        </span>
                        <span>{f}</span>
                      </li>
                    ))}
                  </ul>
                  <Link
                    href={plan.cta.href}
                    className="btn btn-primary mt-6 w-full"
                  >
                    {plan.cta.label}
                  </Link>
                </div>

                <div className="card flex flex-col p-6">
                  <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-[var(--text-dim)]">
                    Optional
                  </div>
                  <h2 className="text-xl font-bold">{SUPPORT.label}</h2>
                  <p className="mt-1 text-sm text-[var(--text-muted)]">
                    Pay what you can — $0 is a fine answer.
                  </p>
                  <p className="mt-4 flex-1 text-sm leading-relaxed text-[var(--text-muted)]">
                    {SUPPORT.blurb}
                  </p>
                  <a
                    href={SUPPORT.href}
                    target="_blank"
                    rel="noreferrer"
                    className="btn btn-secondary mt-6 w-full"
                  >
                    {SUPPORT.label}
                  </a>
                </div>
              </div>
            );
          })()}

          <div className="card mt-10 p-5 text-sm leading-relaxed text-[var(--text-muted)]">
            <h2 className="text-base font-semibold text-[var(--text)]">
              What you always pay separately
            </h2>
            <p className="mt-2">
              OpenAI, Claude, Gemini, and Grok usage is billed by those
              providers to <strong className="text-[var(--text)]">your</strong>{" "}
              keys. PromptParle does not mark up their meter and never touches
              those keys — they stay on your PC.
            </p>
            <p className="mt-2">
              Each desktop needs its own license key (pp_live_) to activate. The
              key is free; it just ties a machine to your account for stats and
              support.
            </p>
          </div>

          <p className="mt-8 text-center text-sm text-[var(--text-dim)]">
            <Link
              href="/trust"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              Trust &amp; data path
            </Link>
            {" · "}
            <Link
              href="/examples"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              Example packs
            </Link>
            {" · "}
            <Link
              href="/faq"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              FAQ
            </Link>
          </p>
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}
