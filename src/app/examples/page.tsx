import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { EXAMPLE_PACKS, packReduction } from "@/lib/example-packs";
import { EXPECTATIONS_BLURB } from "@/lib/heuristics-public";
import { formatNumber } from "@/lib/format";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: {
    absolute: "Example packs · PromptParle",
  },
  description:
    "Illustrative before/after token counts: noisy logs, security review packs, and clean prose. Savings depend on content, not guaranteed percentages.",
  alternates: { canonical: "/examples" },
  robots: { index: true, follow: true },
};

export default function ExamplesPage() {
  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="flex-1">
        <section className="container max-w-3xl py-12 md:py-16">
          <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
            Use cases
          </p>
          <h1 className="page-title mt-2 !mb-2">Published example packs</h1>
          <p className="aeo-direct-answer page-sub !mx-0 !text-left">
            {EXPECTATIONS_BLURB}
          </p>
          <p className="mt-3 text-sm text-[var(--text-dim)]">
            Numbers below are{" "}
            <strong className="text-[var(--text-muted)]">illustrative</strong>{" "}
            demo passes, the kind of work where the dial earns its keep (or
            correctly does almost nothing).
          </p>

          <div className="mt-10 grid gap-6">
            {EXAMPLE_PACKS.map((pack) => {
              const { saved, percent } = packReduction(pack);
              return (
                <article key={pack.id} id={pack.id} className="card overflow-hidden p-0">
                  <div className="border-b border-[var(--border)] px-5 py-4">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <h2 className="text-lg font-semibold">{pack.title}</h2>
                        <p className="mt-1 text-sm text-[var(--text-muted)]">
                          {pack.scenario}
                        </p>
                        <p className="mt-2 text-xs text-[var(--text-dim)]">
                          Profile:{" "}
                          <span className="text-[var(--text-muted)]">
                            {pack.profile}
                          </span>
                          {" · "}
                          Dial {pack.dial}
                        </p>
                      </div>
                      <div className="rounded-xl border border-[var(--border)] bg-[var(--bg-elevated)] px-4 py-3 text-right">
                        <div className="text-2xl font-extrabold text-[var(--success)]">
                          −{percent}%
                        </div>
                        <div className="text-xs text-[var(--text-dim)]">
                          {formatNumber(pack.beforeTokens)} →{" "}
                          {formatNumber(pack.afterTokens)} tok
                        </div>
                        <div className="text-xs text-[var(--text-muted)]">
                          ~{formatNumber(saved)} saved
                        </div>
                      </div>
                    </div>
                    <p className="mt-3 text-sm text-[var(--text-muted)]">
                      {pack.whyItWorks}
                    </p>
                  </div>
                  <div className="grid gap-0 md:grid-cols-2">
                    <div className="border-b border-[var(--border)] p-4 md:border-b-0 md:border-r">
                      <div className="text-xs font-semibold uppercase tracking-wide text-[var(--text-dim)]">
                        Before (shape)
                      </div>
                      <pre className="brand-scroll mt-2 max-h-56 overflow-auto whitespace-pre-wrap rounded-lg bg-black/30 p-3 font-mono text-[0.7rem] leading-relaxed text-[var(--text-muted)] [color-scheme:dark]">
                        {pack.sampleBefore}
                      </pre>
                    </div>
                    <div className="p-4">
                      <div className="text-xs font-semibold uppercase tracking-wide text-[var(--text-dim)]">
                        After (shape)
                      </div>
                      <pre className="brand-scroll mt-2 max-h-56 overflow-auto whitespace-pre-wrap rounded-lg bg-black/30 p-3 font-mono text-[0.7rem] leading-relaxed text-[var(--text-muted)] [color-scheme:dark]">
                        {pack.sampleAfter}
                      </pre>
                    </div>
                  </div>
                </article>
              );
            })}
          </div>

          <div className="card mt-8 p-5 text-sm text-[var(--text-muted)]">
            <h2 className="font-semibold text-[var(--text)]">
              When savings are high vs near-zero
            </h2>
            <ul className="mt-2 list-disc space-y-1 pl-5">
              <li>
                <strong className="text-[var(--text)]">Often high:</strong>{" "}
                noisy logs, duplicated frames, fat security packs, multi-file
                dumps, agent chains that re-ship the same context.
              </li>
              <li>
                <strong className="text-[var(--text)]">Often near-zero:</strong>{" "}
                short unique questions, already-tight prose, single clean
                paragraphs, there is nothing honest to remove.
              </li>
            </ul>
            <figure className="mt-5 overflow-hidden rounded-xl border border-[var(--border)] bg-[#07090f]">
              <picture>
                <source
                  srcSet="/screenshots/desktop-live-savings-banner.webp"
                  type="image/webp"
                />
                <img
                  src="/screenshots/desktop-live-savings-banner.jpg"
                  alt="Desktop savings line after attached guide summary: −86% tokens, 100k → 14k"
                  width={1200}
                  height={280}
                  className="mx-auto h-auto w-full"
                  loading="lazy"
                  decoding="async"
                />
              </picture>
              <figcaption className="border-t border-[var(--border)] px-3 py-2 text-center text-xs text-[var(--text-dim)]">
                Live UI after the attached-guide pack (also on the{" "}
                <Link href="/#how-savings" className="text-[var(--accent-strong)] hover:underline">
                  homepage
                </Link>
                ).
              </figcaption>
            </figure>
            <p className="mt-3">
              Live proof is the savings line in the desktop UI after each turn - {" "}
              <Link
                href="/install"
                className="font-medium text-[var(--accent-strong)] hover:underline"
              >
                install the client
              </Link>
              .
            </p>
          </div>
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}
