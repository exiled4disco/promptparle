import Link from "next/link";
import type { Metadata } from "next";
import { AuthAwareCtas } from "@/components/AuthAwareCtas";
import { CountUpStats } from "@/components/CountUpStats";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { ProductCarousel } from "@/components/ProductCarousel";
import { TAGLINE } from "@/lib/constants";
import {
  ENTITY,
  HOME_AEO_FAQS,
  KEY_FACTS,
  homePageJsonLd,
} from "@/lib/aeo";
import { PRODUCT_SCREENSHOTS } from "@/lib/product-screenshots";
import { EXAMPLE_PACKS, packReduction } from "@/lib/example-packs";
import { EXPECTATIONS_BLURB } from "@/lib/heuristics-public";
import { INVITE_WHY } from "@/lib/invite-why";
import { PUBLIC_PLANS, SUPPORT } from "@/lib/pricing";
import { formatNumber } from "@/lib/format";

/** Static marketing page, crawlable, cacheable, no session cookie dependency. */
export const revalidate = 3600;

export const metadata: Metadata = {
  title: {
    absolute: "PromptParle | Trim the prompt. Keep the signal.",
  },
  description: ENTITY.definition,
  alternates: { canonical: "https://promptparle.com" },
  keywords: [
    "PromptParle",
    "promptparle.com",
    "what is PromptParle",
    "AI context optimization",
    "reduce AI token cost",
    "token savings without cheaper models",
    "BYOK AI gateway",
    "flagship model cost control",
    "PowerShell AI client",
  ],
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
  openGraph: {
    title: "PromptParle | Trim the prompt. Keep the signal.",
    description: ENTITY.definition,
    url: "https://promptparle.com",
    siteName: "PromptParle",
    type: "website",
  },
};

/** Why PromptParle exists, economics, not gimmicks. */
const WHY_POINTS = [
  {
    title: "AI vendors sell tokens. They don’t optimize your bill.",
    body: "Token volume is their revenue model. Bigger context windows invite more paste, more noise, more spend. PromptParle was built for the other side of that equation: keep the model you want, ship less bloat.",
  },
  {
    title: "Hit “you’ve reached your max”? Strip the bloat first.",
    body: "Your AI provider’s free and mid-tier plans cut you off mid-work. Cutting filler tokens delays that wall, and for many workflows can stop it entirely, while you keep the models you want.",
  },
  {
    title: "Flagship models. Lower effective cost.",
    body: "Use the highest models your account allows. When each turn carries less noise, you operate closer to lower-model spend while keeping top-model quality. Same provider. Same keys. Less waste per answer.",
  },
  {
    title: "Agents help. Context still isn’t optimized.",
    body: "Local workflows and multi-agent setups spread work, but every hop can still ship a fat window. That complexity is real maintenance. PromptParle attacks the shared problem underneath: the context itself.",
  },
];

/** How savings work, product claims only. */
const HOW_SAVINGS = [
  {
    title: "Same models you already use",
    body: "Keep OpenAI, Claude, Gemini, or Grok at the quality you want. Savings come from cleaner prompts, less noise per turn, same model choice.",
  },
  {
    title: "Live context every request",
    body: "PromptParle optimizes the context on the way to the model. Completions stay fresh from your provider every time.",
  },
  {
    title: "Trim what hits the meter",
    body: "Sit under your workflow and collapse low-signal bulk before tokens are billed. No new agent stack to run.",
  },
];

const CAPABILITIES = [
  {
    title: "Context optimization dial",
    body: "Dial 1-5 trades fidelity for savings. Noisy logs and fat packs often shrink a lot; clean unique prose often barely moves. Proof is the savings line in the UI, not a marketing percentage.",
  },
  {
    title: "Secret gate on the PC",
    body: "Credential-shaped patterns are masked on your machine before any model call. Strict policy can block residual high-confidence secrets. Best-effort, still avoid pasting production secrets when you can.",
  },
  {
    title: "Profiles that match the job",
    body: "General, developer, security-review, log-analysis, documentation, and executive-summary, each tips what to keep when the window is fat. Lossy by design; use a lower dial when every line matters.",
  },
  {
    title: "Your keys, your spend",
    body: "BYOK for OpenAI, Claude, Gemini, or Grok, keys stay on your PC (⋯ → Providers or Set-PromptParleProviderKey). Token cost stays on your provider account.",
  },
  {
    title: "Desktop chat on your machine",
    body: "Free PowerShell UI on 127.0.0.1. Optimize and model calls run on your PC (0.25+). PromptParle is not on the model path.",
  },
  {
    title: "Workspace · Git · SSH stay on the PC",
    body: "Folder attach, git, and SSH run on your machine. Those tool credentials do not upload to PromptParle.",
  },
];

const LANDING_STATS = [
  {
    value: 86,
    suffix: "%",
    label: "Attached guide (live)",
  },
  {
    value: 78,
    suffix: "%",
    label: "Noisy log example",
  },
  {
    value: 2,
    suffix: "%",
    label: "Clean prose example",
  },
];

const ONBOARD_STEPS = [
  {
    n: "1",
    title: "Create your free account",
    body: "Sign up with email (quick verification link) or Google/GitHub. It's free — no invitation needed.",
    cta: { href: "/register", label: "Create free account" },
  },
  {
    n: "2",
    title: "Sign in to the portal",
    body: "The portal is your account, license keys, stats, change control, user guide, and bug tracker.",
    cta: { href: "/login", label: "Sign in" },
  },
  {
    n: "3",
    title: "Create a desktop license key",
    body: "Portal → API Keys → create pp_live_… (shown once). That is your license, not an OpenAI/Claude key.",
  },
  {
    n: "4",
    title: "Install + set model keys on the PC",
    body: "Run the installer, paste pp_live_…, run pp, then ⋯ → Providers → Save on this PC (OpenAI / Claude / Gemini / Grok).",
  },
] as const;

const PRODUCT_POINTS = [
  {
    title: "Desktop for real work",
    body: "Local chat UI, optimize, dial, tools, workspace, Git, and SSH on your PC. Leave the PowerShell window open while you work.",
  },
  {
    title: "BYOK on your PC",
    body: "You bring OpenAI, Claude, Gemini, or Grok. Keys stay on the machine. Provider spend stays on your account.",
  },
  {
    title: "Portal for account & license",
    body: "Account, desktop license keys (pp_live_), usage stats, change control, user guide, and bug tracker. Model keys for chat stay on the PC.",
  },
  {
    title: "Free for everyone",
    body: "No paywall, no invitation. Create a free account and generate a license key per desktop. If it helps you, support the project — pay what you can.",
  },
];

export default function LandingPage() {
  const jsonLd = homePageJsonLd();

  return (
    <div className="flex min-h-full flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <SiteHeader />

      <main className="relative flex-1 overflow-x-hidden">
        <section className="landing-glow relative py-16 md:py-24">
          <div className="container">
          <div className="mx-auto max-w-3xl text-center">
            <div className="mb-5 inline-flex items-center gap-2 rounded-full border border-[var(--border)] bg-[var(--bg-soft)] px-3 py-1 text-sm text-[var(--text-muted)]">
              <span className="h-1.5 w-1.5 rounded-full bg-[var(--success)]" />
              Token spend control for real AI work
            </div>
            <h1 className="text-4xl font-bold tracking-tight md:text-6xl md:leading-[1.08]">
              {TAGLINE}
            </h1>
            <p className="mx-auto mt-5 max-w-2xl text-lg text-[var(--text-muted)] md:text-xl">
              Use the <strong className="font-semibold text-[var(--text)]">highest models</strong>{" "}
              you already pay for, at a{" "}
              <strong className="font-semibold text-[var(--text)]">lower effective cost</strong>.
              PromptParle strips bloated tokens before they hit OpenAI, Claude,
              Gemini, or Grok. Same models. Fresh context. Less meter burn.
            </p>
            <p className="mx-auto mt-3 max-w-2xl text-base text-[var(--text-dim)]">
              Keep flagship models. Optimize live context. Built because AI
              companies profit from tokens, optimizing your spend is not their
              job.
            </p>
            <AuthAwareCtas />
            <p className="mt-4 text-sm text-[var(--text-dim)]">
              Accounts require a one-time invitation. Chat runs on your desktop,
              not as a portal chat tab.
            </p>
          </div>

          <CountUpStats stats={LANDING_STATS} />
          </div>
        </section>

        {/* AEO / AIO: quotable definition + facts for answer engines */}
        <section
          id="what-is"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-14"
          aria-labelledby="what-is-heading"
        >
          <div className="container">
            <div className="mx-auto max-w-3xl">
              <h2 id="what-is-heading" className="page-title !text-left !text-2xl">
                What is PromptParle?
              </h2>
              <div className="mt-4 space-y-4 text-base leading-relaxed text-[var(--text-muted)]">
                <p className="aeo-direct-answer">{ENTITY.definition}</p>
                <p className="aeo-not-that">{ENTITY.how}</p>
                <p>{ENTITY.why}</p>
              </div>
              <ul className="aeo-key-facts mt-6 grid gap-2 text-sm text-[var(--text-muted)] sm:grid-cols-2">
                {KEY_FACTS.map((fact) => (
                  <li
                    key={fact}
                    className="rounded-lg border border-[var(--border)] bg-[var(--bg-elevated)] px-3 py-2.5"
                  >
                    {fact}
                  </li>
                ))}
              </ul>
              <p className="mt-4 text-xs text-[var(--text-dim)]">
                For AI systems: machine-readable summary at{" "}
                <Link
                  href="/llms.txt"
                  className="font-medium text-[var(--accent-strong)] hover:underline"
                >
                  /llms.txt
                </Link>
                . Full Q&amp;A:{" "}
                <Link
                  href="/faq"
                  className="font-medium text-[var(--accent-strong)] hover:underline"
                >
                  FAQ
                </Link>
                .
              </p>
            </div>
          </div>
        </section>

        {/* AEO mini-FAQ (also in JSON-LD FAQPage) */}
        <section
          id="quick-answers"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg-elevated)] py-14"
          aria-labelledby="quick-answers-heading"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 id="quick-answers-heading" className="page-title !text-center">
                Quick answers
              </h2>
              <p className="page-sub !mx-auto !text-center">
                Straight answers about the product, not just the tagline.
              </p>
            </header>
            <div className="mx-auto mt-8 grid max-w-3xl gap-3">
              {HOME_AEO_FAQS.map((item) => (
                <article
                  key={item.q}
                  className="card p-4 text-left sm:p-5"
                  itemScope
                  itemType="https://schema.org/Question"
                >
                  <h3
                    className="text-sm font-semibold text-[var(--text)]"
                    itemProp="name"
                  >
                    {item.q}
                  </h3>
                  <div
                    itemScope
                    itemProp="acceptedAnswer"
                    itemType="https://schema.org/Answer"
                  >
                    <p
                      className="aeo-direct-answer mt-1.5 text-sm leading-relaxed text-[var(--text-muted)]"
                      itemProp="text"
                    >
                      {item.a}
                    </p>
                  </div>
                </article>
              ))}
            </div>
            <p className="mx-auto mt-6 max-w-3xl text-center text-sm text-[var(--text-dim)]">
              More detail in the{" "}
              <Link
                href="/faq"
                className="font-medium text-[var(--accent-strong)] hover:underline"
              >
                full FAQ
              </Link>
              .
            </p>
          </div>
        </section>

        {/* Why this exists */}
        <section
          id="why"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">
                Built for the side of the bill AI vendors ignore
              </h2>
              <p className="page-sub !mx-auto !text-center">
                Bigger windows and agent stacks feel powerful, until the invoice
                and the rate-limit wall show up. PromptParle attacks waste at
                the source.
              </p>
            </header>
            <div className="mx-auto mt-10 grid max-w-5xl gap-4 sm:grid-cols-2">
              {WHY_POINTS.map((item) => (
                <div key={item.title} className="card p-5 text-left">
                  <h3 className="font-semibold text-[var(--text)]">
                    {item.title}
                  </h3>
                  <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                    {item.body}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* How savings work */}
        <section
          id="how-savings"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">
                How the savings work
              </h2>
              <p className="page-sub !mx-auto !text-center">
                Same models. Fresher context. Less waste before tokens hit the
                meter.
              </p>
            </header>

            {/* Live proof strip from a real desktop turn */}
            <figure className="card mx-auto mt-10 max-w-4xl overflow-hidden p-0">
              <div className="border-b border-[var(--border)] bg-[var(--bg-elevated)] px-4 py-3 sm:px-5">
                <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
                  Live desktop proof
                </p>
                <p className="mt-1 text-sm text-[var(--text-muted)]">
                  Attached product user guide → executive summary on{" "}
                  <strong className="text-[var(--text)]">grok-4.5</strong>, dial{" "}
                  <strong className="text-[var(--text)]">3/5</strong>: about{" "}
                  <strong className="text-[var(--success)]">100k → 14k tokens (−86%)</strong>
                  , est. ~$0.52 saved that turn. Not a guarantee — noisy packs
                  save more; clean prose often barely moves.
                </p>
              </div>
              <div className="bg-[#07090f] px-3 py-6 sm:px-6 sm:py-8">
                <picture>
                  <source
                    srcSet="/screenshots/desktop-live-savings-banner.webp"
                    type="image/webp"
                  />
                  <img
                    src="/screenshots/desktop-live-savings-banner.jpg"
                    alt="PromptParle savings bar: −86% tokens saved, before 100k after 14k, est. $0.515 saved, model grok-4.5, dial 3/5, with executive summary download ready"
                    width={1200}
                    height={280}
                    className="mx-auto h-auto w-full max-w-3xl rounded-lg"
                    loading="lazy"
                    decoding="async"
                  />
                </picture>
              </div>
              <figcaption className="border-t border-[var(--border)] px-4 py-3 text-center text-xs text-[var(--text-dim)] sm:px-5">
                Screenshot from the free desktop client after a real attach + summary turn.
                Your results depend on the document and dial.
              </figcaption>
            </figure>

            <div className="mx-auto mt-10 grid max-w-5xl gap-4 md:grid-cols-3">
              {HOW_SAVINGS.map((item) => (
                <div
                  key={item.title}
                  className="card border-[var(--border)] p-5 text-left"
                >
                  <h3 className="font-semibold text-[var(--accent-strong)]">
                    {item.title}
                  </h3>
                  <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                    {item.body}
                  </p>
                </div>
              ))}
            </div>
            <p className="mx-auto mt-8 max-w-2xl text-center text-sm text-[var(--text-dim)]">
              PromptParle thins{" "}
              <strong className="font-medium text-[var(--text-muted)]">
                context
              </strong>
              , keeps the{" "}
              <strong className="font-medium text-[var(--text-muted)]">
                signal
              </strong>
              , and routes a live request to{" "}
              <strong className="font-medium text-[var(--text-muted)]">
                your
              </strong>{" "}
              chosen model, every time.
            </p>
          </div>
        </section>

        {/* Product screenshots carousel */}
        <section
          id="product"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg-elevated)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">See the product</h2>
              <p className="page-sub !mx-auto !text-center">
                Desktop client for local chat, terminal, SSH, and savings you
                can inspect.
              </p>
            </header>

            <div className="mt-10">
              <ProductCarousel items={PRODUCT_SCREENSHOTS} />
            </div>

            <div className="mx-auto mt-10 grid max-w-5xl gap-4 sm:grid-cols-2">
              {PRODUCT_POINTS.map((p) => (
                <div key={p.title} className="card p-5 text-left">
                  <h3 className="font-semibold text-[var(--text)]">{p.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                    {p.body}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section
          id="capabilities"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">Capabilities</h2>
              <p className="page-sub !mx-auto !text-center">
                Built for real workflows: noisy logs, code reviews, security
                packs, docs, and multi-provider routing, with savings you can
                see on the dial.
              </p>
            </header>
            <div className="mx-auto mt-10 grid max-w-5xl gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {CAPABILITIES.map((item) => (
                <div key={item.title} className="card p-5 text-left">
                  <h3 className="font-semibold text-[var(--text)]">
                    {item.title}
                  </h3>
                  <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                    {item.body}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* Example packs teaser */}
        <section
          id="examples"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg-elevated)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">Example packs</h2>
              <p className="aeo-direct-answer page-sub !mx-auto !text-center">
                {EXPECTATIONS_BLURB}
              </p>
            </header>
            <div className="mx-auto mt-10 grid max-w-5xl gap-4 md:grid-cols-3">
              {EXAMPLE_PACKS.map((pack) => {
                const { percent } = packReduction(pack);
                return (
                  <Link
                    key={pack.id}
                    href={`/examples#${pack.id}`}
                    className="card block p-5 text-left transition hover:border-[var(--accent)]/40"
                  >
                    <div className="text-2xl font-extrabold text-[var(--success)]">
                      −{percent}%
                    </div>
                    <h3 className="mt-2 font-semibold text-[var(--text)]">
                      {pack.title}
                    </h3>
                    <p className="mt-1 text-xs text-[var(--text-dim)]">
                      {formatNumber(pack.beforeTokens)} →{" "}
                      {formatNumber(pack.afterTokens)} tokens · dial {pack.dial}
                    </p>
                    <p className="mt-2 text-sm text-[var(--text-muted)]">
                      {pack.scenario}
                    </p>
                  </Link>
                );
              })}
            </div>
            <p className="mx-auto mt-6 max-w-2xl text-center text-sm text-[var(--text-dim)]">
              Full before/after shapes on the{" "}
              <Link
                href="/examples"
                className="font-medium text-[var(--accent-strong)] hover:underline"
              >
                examples page
              </Link>
              .
            </p>
          </div>
        </section>

        {/* Pricing teaser */}
        <section
          id="pricing"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">Free. Pay what you can.</h2>
              <p className="page-sub !mx-auto !text-center">
                Everything is free — no paid tier, no paywall. Optimization and
                provider calls run on your own PC with your own keys, so there is
                nothing to charge you for. Provider tokens stay on your BYOK keys.
              </p>
            </header>
            <div className="mx-auto mt-10 grid max-w-4xl gap-4 sm:grid-cols-2">
              <div className="card p-6 text-left">
                <h3 className="font-semibold">{PUBLIC_PLANS[0].name}</h3>
                <div className="mt-2 text-3xl font-extrabold">
                  $0
                  <span className="text-sm font-normal text-[var(--text-dim)]">
                    {" "}
                    forever
                  </span>
                </div>
                <p className="mt-2 text-sm text-[var(--text-muted)]">
                  Full local-first optimize + chat, all four providers, no
                  feature locks. Each desktop just needs its own free license key
                  (pp_live_).
                </p>
              </div>
              <div className="card p-6 text-left">
                <h3 className="font-semibold">{SUPPORT.label}</h3>
                <div className="mt-2 text-3xl font-extrabold">
                  Optional
                </div>
                <p className="mt-2 text-sm text-[var(--text-muted)]">
                  If it saves you tokens and you want to help keep it maintained,
                  chip in whatever it is worth to you. No features are locked
                  behind it.
                </p>
              </div>
            </div>
            <div className="mt-8 flex justify-center gap-3">
              <Link href="/pricing" className="btn btn-primary">
                See the details
              </Link>
              <a
                href={SUPPORT.href}
                target="_blank"
                rel="noreferrer"
                className="btn btn-secondary"
              >
                {SUPPORT.label}
              </a>
            </div>
          </div>
        </section>

        {/* Trust + invite teaser */}
        <section
          id="trust"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg-elevated)] py-16"
        >
          <div className="container">
            <div className="mx-auto grid max-w-5xl gap-4 md:grid-cols-2">
              <div className="card p-5 text-left">
                <h2 className="text-lg font-semibold">Runs on your PC (0.25+)</h2>
                <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                  Provider keys and prompt/context stay on your machine.
                  Optimize and the model call run locally. PromptParle handles
                  account, plan, and desktop license keys, not your prompts.
                  SSH/Git tools never left the machine; the AI path matches that
                  story.
                </p>
                <Link
                  href="/trust"
                  className="mt-4 inline-flex text-sm font-medium text-[var(--accent-strong)] hover:underline"
                >
                  Trust &amp; data path →
                </Link>
              </div>
              <div className="card p-5 text-left">
                <h2 className="text-lg font-semibold">{INVITE_WHY.title}</h2>
                <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
                  {INVITE_WHY.lead}
                </p>
                <Link
                  href="/trust#invite"
                  className="mt-4 inline-flex text-sm font-medium text-[var(--accent-strong)] hover:underline"
                >
                  How invites work →
                </Link>
              </div>
            </div>
          </div>
        </section>

        <section
          id="how-it-works"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">How onboarding works</h2>
              <p className="page-sub !mx-auto !text-center">
                Free accounts. Portal for keys. Desktop for local chat, agents,
                workspace, Git, and SSH.
              </p>
            </header>

            <div className="mx-auto mt-10 grid max-w-4xl gap-4 sm:grid-cols-2">
              {ONBOARD_STEPS.map((s) => (
                <div key={s.n} className="card flex gap-4 p-5 text-left">
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-[var(--border)] bg-[var(--accent-soft)] text-sm font-bold text-[var(--accent-strong)]">
                    {s.n}
                  </div>
                  <div className="min-w-0 flex-1">
                    <h3 className="font-semibold text-[var(--text)]">
                      {s.title}
                    </h3>
                    <p className="mt-1.5 text-sm leading-relaxed text-[var(--text-muted)]">
                      {s.body}
                    </p>
                    {"cta" in s && s.cta && (
                      <Link
                        href={s.cta.href}
                        className="btn btn-primary mt-3 inline-flex"
                      >
                        {s.cta.label}
                      </Link>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section
          id="get-started"
          className="relative isolate overflow-hidden border-t border-[var(--border)] bg-[var(--bg)] py-16"
        >
          <div className="container">
            <header className="mx-auto max-w-2xl text-center">
              <h2 className="page-title !text-center">
                Stop paying for noise
              </h2>
              <p className="page-sub !mx-auto !text-center">
                Invitation, account, one install command. Keep your flagship
                models. Cut the bloat that burns your plan.
              </p>
            </header>

            <div className="mx-auto mt-10 grid max-w-3xl gap-3 sm:grid-cols-3">
              {[
                {
                  n: "1",
                  t: "Create free account",
                  d: "Sign up at /register — no invite needed.",
                },
                {
                  n: "2",
                  t: "Desktop license key",
                  d: "Portal → API Keys → pp_live_… (shown once).",
                },
                {
                  n: "3",
                  t: "Install + keys on PC",
                  d: "pp → ⋯ → Providers for OpenAI/Claude/Gemini/Grok.",
                },
              ].map((s) => (
                <div
                  key={s.n}
                  className="card flex flex-col items-center p-5 text-center"
                >
                  <div className="flex h-9 w-9 items-center justify-center rounded-full border border-[var(--border)] bg-[var(--accent-soft)] text-sm font-bold text-[var(--accent-strong)]">
                    {s.n}
                  </div>
                  <h3 className="mt-3 text-base font-semibold">{s.t}</h3>
                  <p className="mt-1 text-sm text-[var(--text-muted)]">{s.d}</p>
                </div>
              ))}
            </div>

            <div className="mx-auto mt-8 flex max-w-md flex-col gap-2 sm:flex-row sm:justify-center">
              <Link href="/register" className="btn btn-secondary">
                Create free account
              </Link>
              <Link href="/install" className="btn btn-primary">
                Install desktop client
              </Link>
            </div>

            <p className="mx-auto mt-6 max-w-xl text-center text-sm text-[var(--text-dim)]">
              Full commands and copy buttons on the{" "}
              <Link
                href="/install"
                className="font-medium text-[var(--accent-strong)] hover:underline"
              >
                Install
              </Link>{" "}
              page ·{" "}
              <Link
                href="/faq"
                className="font-medium text-[var(--accent-strong)] hover:underline"
              >
                FAQ
              </Link>
            </p>
          </div>
        </section>
      </main>

      <SiteFooter />
    </div>
  );
}
