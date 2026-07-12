import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import {
  PUBLIC_PLANS,
  YEARLY_DISCOUNT_PERCENT,
  formatUsd,
} from "@/lib/pricing";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: {
    absolute: "Pricing · PromptParle (promptparle.com)",
  },
  description:
    "Flat PromptParle pricing: Free $0, Pro $29.99/mo, Team of 5 $99.99/mo. 20% off yearly. AI provider tokens billed separately via BYOK.",
  alternates: { canonical: "/pricing" },
  robots: { index: true, follow: true },
  openGraph: {
    title: "PromptParle pricing",
    description:
      "Simple flat plans. Free, Pro $29.99, Team of 5 $99.99. Yearly save 20%. Tokens stay on your provider keys.",
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
          <h1 className="page-title mt-2 !mb-2">Flat plans. Clear bill.</h1>
          <p className="aeo-direct-answer page-sub !mx-0 max-w-2xl !text-left">
            PromptParle is{" "}
            <strong className="text-[var(--text)]">fixed monthly or yearly</strong>, not priced by the request. Your AI provider still bills tokens on
            your BYOK keys. We just help those tokens work harder.
          </p>
          <p className="mt-3 text-sm text-[var(--text-dim)]">
            Yearly billing saves <strong className="text-[var(--text-muted)]">{YEARLY_DISCOUNT_PERCENT}%</strong>.
            Access is invitation-only while we scale the experience.
          </p>

          <div className="mt-10 grid gap-4 lg:grid-cols-3">
            {PUBLIC_PLANS.map((plan) => (
              <div
                key={plan.id}
                className={`card flex flex-col p-5 ${
                  plan.highlighted
                    ? "border-[var(--accent)]/50 ring-1 ring-[var(--accent)]/30"
                    : ""
                }`}
              >
                {plan.highlighted && (
                  <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
                    Popular
                  </div>
                )}
                <h2 className="text-xl font-bold">{plan.name}</h2>
                <p className="mt-1 text-sm text-[var(--text-muted)]">
                  {plan.tagline}
                </p>
                <div className="mt-4">
                  <div className="flex items-baseline gap-1">
                    <span className="text-3xl font-extrabold tracking-tight">
                      {formatUsd(plan.priceMonthly)}
                    </span>
                    {plan.priceMonthly > 0 && (
                      <span className="text-sm text-[var(--text-dim)]">/mo</span>
                    )}
                  </div>
                  {plan.priceMonthly > 0 ? (
                    <p className="mt-1 text-xs text-[var(--text-dim)]">
                      or {formatUsd(plan.priceYearly)}/yr (
                      {formatUsd(plan.priceYearlyPerMonth)}/mo · save{" "}
                      {YEARLY_DISCOUNT_PERCENT}%)
                    </p>
                  ) : (
                    <p className="mt-1 text-xs text-[var(--text-dim)]">
                      Forever free tier · invite required
                    </p>
                  )}
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
                  className={
                    plan.highlighted
                      ? "btn btn-primary mt-6 w-full"
                      : "btn btn-secondary mt-6 w-full"
                  }
                >
                  {plan.cta.label}
                </Link>
              </div>
            ))}
          </div>

          <div className="card mt-10 p-5 text-sm leading-relaxed text-[var(--text-muted)]">
            <h2 className="text-base font-semibold text-[var(--text)]">
              What you always pay separately
            </h2>
            <p className="mt-2">
              OpenAI, Claude, Gemini, and Grok usage is billed by those
              providers to <strong className="text-[var(--text)]">your</strong>{" "}
              keys. PromptParle does not mark up their meter. Our subscription is
              for the optimization gateway, desktop client, and portal.
            </p>
            <p className="mt-2">
              Soft fair-use protection may still apply on free accounts so the
              fleet stays healthy, that is not how we price Pro or Team.
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
