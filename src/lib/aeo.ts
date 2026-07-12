/**
 * AEO (Answer Engine Optimization) + AIO (AI Overview / AI crawler) helpers.
 * Keep entity names and short answers consistent so engines cite one story.
 */

import { TAGLINE } from "./constants";
import { absoluteUrl, siteUrl } from "./site";

export const ENTITY = {
  name: "PromptParle",
  officialUrl: "https://promptparle.com",
  tagline: TAGLINE,
  /**
   * One-sentence definition for answer engines to quote.
   */
  definition:
    "PromptParle is an AI context optimization gateway that sits between your desktop tools and providers such as OpenAI, Claude, Gemini, and Grok. It strips bloated tokens, keeps the useful signal, and routes live prompts so you can use flagship models at a lower effective cost.",
  /** Second-line product claim (AIO snippet). */
  how:
    "You keep your model choice. Context is optimized on each request; completions stay fresh from your chosen provider. Savings come from less bloat, not a silent quality trade-off.",
  why:
    "AI companies earn revenue from tokens, so they are not built to shrink your spend. PromptParle exists for the buyer side: same models, less noise, fewer plan-limit walls.",
  access:
    "PromptParle is free and open to sign up. Chat runs in a free local desktop client on your PC; the portal handles your account, plan, and desktop license keys (pp_live_). Provider API keys are set on the PC. Create a free account at https://promptparle.com/register.",
  privacy:
    "Desktop 0.25+ keeps provider keys and prompt/context on your PC; optimize and model calls run locally. The portal handles account, plan, and desktop license keys. SSH/git tool credentials stay on the desktop.",
} as const;

/** Homepage mini-FAQ for AEO (also powers FAQPage schema on home). */
export const HOME_AEO_FAQS: Array<{ q: string; a: string }> = [
  {
    q: "What is PromptParle?",
    a: ENTITY.definition,
  },
  {
    q: "How does PromptParle save tokens?",
    a: "It thins bloated context before the model call. You keep your OpenAI, Claude, Gemini, or Grok model choice; completions stay live from your provider.",
  },
  {
    q: "Who pays for AI tokens?",
    a: "You do, via bring-your-own-key (BYOK) on your PC. Provider usage is billed by OpenAI, Anthropic, Google, or xAI to your account. PromptParle reduces how much noisy context you send.",
  },
  {
    q: "Where does chat run?",
    a: "The chat UI runs in a free desktop client on your machine (127.0.0.1). Optimize and model calls run on the PC; the portal is for account, plan, and desktop license keys.",
  },
  {
    q: "Where do I put OpenAI or Claude API keys?",
    a: "On your PC: run pp, then ⋯ → Providers → Save on this PC, or Set-PromptParleProviderKey. The portal only needs a pp_live_ desktop license key.",
  },
  {
    q: "Does my prompt leave my machine?",
    a: "On desktop 0.25+: optimize stays on the PC; model calls go from your PC to your AI provider with your local key. PromptParle is not on the model path. See https://promptparle.com/trust",
  },
  {
    q: "How do I get access?",
    a: "PromptParle is free and open. Create an account at promptparle.com/register with email + password (or Google / GitHub), then make a desktop license key and install the client. No invitation required.",
  },
];

/** Quotable facts for AI Overviews / list answers. */
export const KEY_FACTS: string[] = [
  "Context optimization gateway for OpenAI, Claude, Gemini, and Grok (BYOK).",
  "Flagship models stay available; savings come from less bloat.",
  "Live optimization every request; fresh completions from your provider.",
  "Desktop 0.25+: optimize + model calls on your PC; portal handles license and account.",
  "Provider keys live on the PC only. Prompt/context do not go to PromptParle on local-first clients.",
  "Example packs so far: Noisy ~78%, Security ~60%, Clean ~2%, still measuring real workloads.",
  "Free and open to sign up at promptparle.com/register; each desktop uses its own pp_live_ license key.",
];

export function organizationJsonLd() {
  const base = siteUrl();
  return {
    "@type": "Organization",
    "@id": `${base}/#organization`,
    name: ENTITY.name,
    legalName: "PromptParle",
    alternateName: ["PromptParle.com", "promptparle.com"],
    url: `${base}/`,
    logo: {
      "@type": "ImageObject",
      url: absoluteUrl("/logo.png"),
      width: 512,
      height: 512,
    },
    description: ENTITY.definition,
    sameAs: ["https://github.com/exiled4disco/promptparle"] as string[],
    identifier: {
      "@type": "PropertyValue",
      name: "officialDomain",
      value: "promptparle.com",
    },
  };
}

export function websiteJsonLd() {
  const base = siteUrl();
  return {
    "@type": "WebSite",
    "@id": `${base}/#website`,
    url: `${base}/`,
    name: "PromptParle",
    alternateName: ["promptparle.com", "PromptParle AI"],
    description: ENTITY.tagline,
    publisher: { "@id": `${base}/#organization` },
    inLanguage: "en-US",
    potentialAction: {
      "@type": "SearchAction",
      target: {
        "@type": "EntryPoint",
        urlTemplate: `${base}/faq?q={search_term_string}`,
      },
      "query-input": "required name=search_term_string",
    },
  };
}

export function softwareJsonLd() {
  const base = siteUrl();
  return {
    "@type": "SoftwareApplication",
    "@id": `${base}/#software`,
    name: "PromptParle",
    alternateName: ["PromptParle desktop", "pp client"],
    applicationCategory: "DeveloperApplication",
    applicationSubCategory: "AI context optimization gateway",
    operatingSystem: "Windows, Linux, macOS",
    url: `${base}/`,
    downloadUrl: absoluteUrl("/install"),
    description: ENTITY.definition,
    offers: {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
      description:
        "Desktop client is free; AI provider usage is billed by your BYOK provider.",
    },
    featureList: [
      "Context optimization dial (1-5)",
      "Secret masking on the PC before provider calls",
      "BYOK for OpenAI, Claude, Gemini, Grok (keys on your PC)",
      "Local desktop chat UI; optimize and model calls on your machine",
      "Token stats and session titles only (no prompt-body storage by default)",
      "Workspace, Git, and SSH tools on the local machine",
    ],
    isAccessibleForFree: true,
    browserRequirements: "Requires local desktop client for chat",
  };
}

export function homePageJsonLd() {
  const base = siteUrl();
  return {
    "@context": "https://schema.org",
    "@graph": [
      organizationJsonLd(),
      websiteJsonLd(),
      softwareJsonLd(),
      {
        "@type": "WebPage",
        "@id": `${base}/#webpage`,
        url: `${base}/`,
        name: `PromptParle | ${ENTITY.tagline}`,
        description: ENTITY.definition,
        isPartOf: { "@id": `${base}/#website` },
        about: { "@id": `${base}/#software` },
        primaryImageOfPage: {
          "@type": "ImageObject",
          url: absoluteUrl("/logo.png"),
        },
        inLanguage: "en-US",
        speakable: {
          "@type": "SpeakableSpecification",
          cssSelector: [
            ".aeo-direct-answer",
            ".aeo-key-facts",
            ".aeo-not-that",
          ],
        },
        mainEntity: { "@id": `${base}/#software` },
      },
      {
        "@type": "FAQPage",
        "@id": `${base}/#home-faq`,
        url: `${base}/`,
        name: "PromptParle quick answers",
        isPartOf: { "@id": `${base}/#website` },
        mainEntity: HOME_AEO_FAQS.map((item) => ({
          "@type": "Question",
          name: item.q,
          acceptedAnswer: {
            "@type": "Answer",
            text: item.a,
          },
        })),
      },
    ],
  };
}

export function howToInstallJsonLd() {
  const base = siteUrl();
  return {
    "@context": "https://schema.org",
    "@type": "HowTo",
    "@id": `${base}/install#howto`,
    name: "How to install the PromptParle desktop client",
    description:
      "Install PromptParle: create a free account, make a desktop license key (pp_live_), run one install command, then set provider keys on the PC.",
    totalTime: "PT10M",
    tool: [
      { "@type": "HowToTool", name: "PowerShell 5.1+ or PowerShell 7" },
      { "@type": "HowToTool", name: "Git" },
    ],
    step: [
      {
        "@type": "HowToStep",
        position: 1,
        name: "Create a free account",
        text: "Sign up at promptparle.com/register with email + password (or Google / GitHub). It's free and open, no invitation required.",
        url: absoluteUrl("/register"),
      },
      {
        "@type": "HowToStep",
        position: 2,
        name: "Create your desktop license key",
        text: "In the portal, create a desktop license key (pp_live_…) for each machine. OpenAI/Claude/Gemini/Grok keys are set later on the PC, not in the portal.",
        url: absoluteUrl("/register"),
      },
      {
        "@type": "HowToStep",
        position: 3,
        name: "Install, then set provider keys locally",
        text: "On Windows: irm https://promptparle.com/install.ps1 | iex. Paste pp_live_…, run pp, then ⋯ → Providers → Save on this PC (or Set-PromptParleProviderKey).",
        url: absoluteUrl("/install"),
      },
    ],
  };
}
