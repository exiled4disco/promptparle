import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { FaqList } from "@/components/FaqList";
import { FAQ_ITEMS, FAQ_CATEGORIES } from "@/lib/faq";
import { ENTITY } from "@/lib/aeo";
import { absoluteUrl, siteUrl } from "@/lib/site";

/** Static FAQ for search / AI crawlers (primary AEO Q&A corpus). */
export const revalidate = 3600;

const PAGE_TITLE =
  "PromptParle FAQ: Desktop Client, Invitations, BYOK & Privacy";
const PAGE_DESCRIPTION = `${ENTITY.definition} Invitation-only while we scale; desktop chat with provider keys on your PC.`;

export const metadata: Metadata = {
  title: {
    absolute: PAGE_TITLE,
  },
  description: PAGE_DESCRIPTION,
  keywords: [
    "PromptParle FAQ",
    "PromptParle",
    "AI context optimization",
    "token savings",
    "BYOK",
    "desktop AI client",
    "PowerShell AI",
    "invitation only AI gateway",
    "OpenAI Claude Gemini Grok",
    "secret masking",
    "pp_live API key",
  ],
  alternates: {
    canonical: "/faq",
  },
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
    type: "website",
    url: "/faq",
    siteName: "PromptParle",
    title: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
    images: [
      {
        url: "/logo.png",
        width: 512,
        height: 512,
        alt: "PromptParle",
      },
    ],
  },
  twitter: {
    card: "summary",
    title: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
    images: ["/logo.png"],
  },
  category: "technology",
};

function buildJsonLd() {
  const base = siteUrl();
  const faqPageId = absoluteUrl("/faq");

  const faqSchema = {
    "@type": "FAQPage",
    "@id": `${faqPageId}#faq`,
    url: faqPageId,
    name: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
    inLanguage: "en-US",
    isPartOf: { "@id": `${base}/#website` },
    about: {
      "@type": "SoftwareApplication",
      name: "PromptParle",
      applicationCategory: "DeveloperApplication",
      operatingSystem: "Windows, Linux, macOS",
      description:
        "AI context optimization gateway with a local desktop client and invitation-only portal for keys and usage.",
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
        description: "Desktop client is free; AI provider usage is billed by your BYOK provider.",
      },
    },
    mainEntity: FAQ_ITEMS.map((item) => ({
      "@type": "Question",
      name: item.q,
      acceptedAnswer: {
        "@type": "Answer",
        text: item.a,
      },
    })),
  };

  const breadcrumb = {
    "@type": "BreadcrumbList",
    "@id": `${faqPageId}#breadcrumb`,
    itemListElement: [
      {
        "@type": "ListItem",
        position: 1,
        name: "Home",
        item: `${base}/`,
      },
      {
        "@type": "ListItem",
        position: 2,
        name: "FAQ",
        item: faqPageId,
      },
    ],
  };

  const website = {
    "@type": "WebSite",
    "@id": `${base}/#website`,
    url: `${base}/`,
    name: "PromptParle",
    description:
      "Trim the prompt. Keep the signal. AI context optimization gateway.",
    publisher: { "@id": `${base}/#organization` },
    inLanguage: "en-US",
  };

  const organization = {
    "@type": "Organization",
    "@id": `${base}/#organization`,
    name: "PromptParle",
    url: `${base}/`,
    logo: {
      "@type": "ImageObject",
      url: absoluteUrl("/logo.png"),
    },
  };

  const webpage = {
    "@type": "WebPage",
    "@id": faqPageId,
    url: faqPageId,
    name: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
    isPartOf: { "@id": `${base}/#website` },
    about: { "@id": `${base}/#organization` },
    breadcrumb: { "@id": `${faqPageId}#breadcrumb` },
    primaryImageOfPage: {
      "@type": "ImageObject",
      url: absoluteUrl("/logo.png"),
    },
    inLanguage: "en-US",
    speakable: {
      "@type": "SpeakableSpecification",
      cssSelector: [".faq-direct-answer", ".faq-summary-lead"],
    },
  };

  return {
    "@context": "https://schema.org",
    "@graph": [organization, website, webpage, breadcrumb, faqSchema],
  };
}

export default function FaqPage() {
  const jsonLd = buildJsonLd();
  const categoryCount = FAQ_CATEGORIES.length;
  const questionCount = FAQ_ITEMS.length;

  return (
    <div className="flex min-h-full flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />

      <SiteHeader />

      <main className="container flex-1 py-10 md:py-14">
        <div className="mx-auto max-w-3xl">
          <nav
            className="mb-6 text-xs text-[var(--text-dim)]"
            aria-label="Breadcrumb"
          >
            <ol className="flex flex-wrap items-center gap-1.5">
              <li>
                <Link href="/" className="hover:text-[var(--text)]">
                  Home
                </Link>
              </li>
              <li aria-hidden>/</li>
              <li className="text-[var(--text-muted)]">FAQ</li>
            </ol>
          </nav>

          <header className="w-full text-left">
            <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
              Help center
            </p>
            <h1 className="page-title !mb-2 !mt-1 !text-left">
              PromptParle frequently asked questions
            </h1>
            <p className="faq-summary-lead page-sub !mx-0 !mt-0 max-w-2xl !text-left text-sm">
              Direct answers about what PromptParle is, how invitation-only
              access works (temporary while we scale), the free desktop client,
              where to put BYOK provider keys (on your PC), privacy, and
              savings expectations.
            </p>
          </header>

          {/* AEO/AIO: short definition block answer engines can quote */}
          <section
            className="card mt-8 p-5"
            aria-labelledby="faq-what-is"
          >
            <h2 id="faq-what-is" className="text-base font-semibold text-[var(--text)]">
              What is PromptParle?
            </h2>
            <p className="faq-direct-answer aeo-direct-answer mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
              <strong className="text-[var(--text)]">PromptParle</strong>{" "}
              {ENTITY.definition.replace(/^PromptParle is /, "is ")}{" "}
              {ENTITY.how} {ENTITY.access}
            </p>
            <ul className="mt-4 grid gap-2 text-sm text-[var(--text-muted)] sm:grid-cols-2">
              <li>
                <strong className="text-[var(--text)]">Access:</strong>{" "}
                invitation-only (no open signup)
              </li>
              <li>
                <strong className="text-[var(--text)]">Chat:</strong> desktop
                client only (not a portal chat tab)
              </li>
              <li>
                <strong className="text-[var(--text)]">Keys:</strong> model keys
                on the PC; portal only hashes desktop license keys
              </li>
              <li>
                <strong className="text-[var(--text)]">Savings:</strong> less
                context waste, same models, live completions
              </li>
            </ul>
          </section>

          <p className="mt-6 text-sm text-[var(--text-dim)]">
            {questionCount} questions across {categoryCount} topics. Jump to:{" "}
            {FAQ_CATEGORIES.map((c, i) => (
              <span key={c}>
                {i > 0 ? " · " : null}
                <a
                  href={`#faq-${c.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")}`}
                  className="text-[var(--accent-strong)] hover:underline"
                >
                  {c}
                </a>
              </span>
            ))}
            .
          </p>

          <div className="mt-8">
            <FaqList items={FAQ_ITEMS} />
          </div>

          <section className="mt-12 grid gap-3 border-t border-[var(--border)] pt-8">
            <h2 className="text-base font-semibold text-[var(--text)]">
              Related pages
            </h2>
            <ul className="grid gap-2 text-sm text-[var(--text-muted)] sm:grid-cols-2">
              <li>
                <Link
                  href="/#product"
                  className="text-[var(--accent-strong)] hover:underline"
                >
                  Product overview & screenshots
                </Link>
              </li>
              <li>
                <Link
                  href="/install"
                  className="text-[var(--accent-strong)] hover:underline"
                >
                  Install desktop client
                </Link>
              </li>
              <li>
                <Link
                  href="/request-invite"
                  className="text-[var(--accent-strong)] hover:underline"
                >
                  Request an invitation
                </Link>
              </li>
              <li>
                <a
                  href="https://github.com/exiled4disco/promptparle"
                  className="text-[var(--accent-strong)] hover:underline"
                  target="_blank"
                  rel="noreferrer"
                >
                  GitHub repository
                </a>
              </li>
            </ul>
            <p className="text-xs text-[var(--text-dim)]">
              This FAQ is product-facing. It does not document proprietary
              implementation details. For regulated work, validate provider
              terms and your own compliance requirements.
            </p>
          </section>
        </div>
      </main>

      <SiteFooter />
    </div>
  );
}
