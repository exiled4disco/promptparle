/**
 * Product model (0.32.0): PromptParle is FREE for everyone.
 *
 * There is no paid tier and no paywall. Optimization + provider calls run on the
 * user's own PC with their own keys (BYOK), so the portal never proxies prompts and
 * carries no per-request server cost — nothing to meter or throttle for money. The
 * portal is licensing + stats + support only (issue a `pp_live_` desktop key per
 * machine, show usage/savings, bug tracker, settings).
 *
 * Support is a PAY-WHAT-YOU-WANT donation (optional, no features gated behind it) to
 * help keep the project maintained. See `SUPPORT` below.
 *
 * `PublicPlanId`/`PublicPlan`/`PUBLIC_PLANS` are kept (single "free" entry) so existing
 * imports keep compiling; the array is no longer a price ladder.
 */

export type PublicPlanId = "free";

export type PublicPlan = {
  id: PublicPlanId;
  name: string;
  tagline: string;
  /** Always 0 — the product is free. */
  priceMonthly: number;
  priceYearly: number;
  priceYearlyPerMonth: number;
  /** Desktop seats per account. One license key per machine; heartbeat frees idle seats. */
  seats: number;
  features: string[];
  cta: { href: string; label: string };
  highlighted?: boolean;
};

/** Optional supporter donation — no fixed price, no gated features. */
export const SUPPORT = {
  /** Where "Support the project" links point. Update to the live sponsor URL. */
  href: "https://github.com/sponsors/exiled4disco",
  label: "Support the project",
  blurb:
    "PromptParle is free. If it saves you tokens and you'd like to help keep it maintained, chip in whatever it's worth to you — pay what you want. No features are locked behind it.",
} as const;

export const PUBLIC_PLANS: PublicPlan[] = [
  {
    id: "free",
    name: "Free — everything",
    tagline: "The whole gateway, free. Optional donation if it helps you.",
    priceMonthly: 0,
    priceYearly: 0,
    priceYearlyPerMonth: 0,
    seats: 1,
    features: [
      "Full local-first optimize + chat (no feature paywall)",
      "BYOK on your PC (OpenAI / Claude / Gemini / Grok)",
      "Context dial + profiles + on-PC secret gate",
      "Desktop license key (pp_live_) per machine",
      "Usage + savings stats, bug tracker, settings in the portal",
      "Prompts + provider keys never leave your PC",
    ],
    cta: { href: "/register", label: "Create free account" },
    highlighted: true,
  },
];

export function formatUsd(n: number): string {
  if (n === 0) return "$0";
  return n % 1 === 0 ? `$${n}` : `$${n.toFixed(2)}`;
}

/**
 * Per-model INPUT token list prices, USD per 1M input tokens.
 *
 * ESTIMATES ONLY. These are approximate public/blended list prices used solely
 * to give the portal a rough "dollars saved" figure for token savings. They are
 * not billing-authoritative and will drift as vendors update pricing. BYOK spend
 * is always metered by the provider. Keys mirror families in src/lib/models.ts.
 */
export const MODEL_INPUT_PRICE_PER_1M: Record<string, number> = {
  // OpenAI (gpt-5.x / gpt-4.x / o-series)
  "gpt-5.5-pro": 15,
  "gpt-5.5": 1.25,
  "gpt-5.4-pro": 15,
  "gpt-5.4": 1.25,
  "gpt-5.4-mini": 0.25,
  "gpt-5.4-nano": 0.05,
  "gpt-5.3": 1.25,
  "gpt-5.2-pro": 15,
  "gpt-5.2": 1.25,
  "gpt-5.1": 1.25,
  "gpt-5-pro": 15,
  "gpt-5": 1.25,
  "gpt-5-mini": 0.25,
  "gpt-5-nano": 0.05,
  o3: 2,
  "o3-mini": 1.1,
  "o4-mini": 1.1,
  o1: 15,
  "o1-pro": 150,
  "gpt-4.1": 2,
  "gpt-4.1-mini": 0.4,
  "gpt-4.1-nano": 0.1,
  "gpt-4o": 2.5,
  "gpt-4o-mini": 0.15,
  "gpt-4-turbo": 10,
  // Anthropic (opus / sonnet / haiku / fable)
  "claude-opus": 15,
  "claude-sonnet": 3,
  "claude-haiku": 0.8,
  "claude-fable": 3,
  // Google Gemini
  "gemini-2.5-pro": 1.25,
  "gemini-2.5-flash": 0.3,
  "gemini-2.5-flash-lite": 0.1,
  "gemini-2.0-flash": 0.1,
  "gemini-2.0-flash-lite": 0.075,
  "gemini-2.0-pro": 1.25,
  "gemini-1.5-pro": 1.25,
  "gemini-1.5-flash": 0.075,
  "gemini-1.5-flash-8b": 0.0375,
  // xAI Grok
  "grok-4.5": 3,
  "grok-4.3": 3,
  "grok-4.20": 3,
  "grok-4": 3,
  "grok-4-fast": 0.2,
  "grok-3": 3,
  "grok-3-fast": 5,
  "grok-3-mini": 0.3,
  "grok-3-mini-fast": 0.6,
};

/** Vendor-neutral fallback ($/1M input tokens) when a model isn't matched. */
const DEFAULT_INPUT_PRICE_PER_1M = 2;

/**
 * Vendor-neutral token estimate from a character count.
 * ~4 chars/token is the common rough heuristic across major tokenizers.
 */
export function tokensFromChars(chars: number): number {
  if (!Number.isFinite(chars) || chars <= 0) return 0;
  return Math.ceil(chars / 4);
}

/**
 * Longest-prefix match of a model id against MODEL_INPUT_PRICE_PER_1M.
 * e.g. "claude-opus-4-8" → "claude-opus", "gpt-5.4-mini-2026" → "gpt-5.4-mini".
 */
function inputPricePer1M(model: string): number {
  const id = (model || "").trim().toLowerCase();
  if (!id) return DEFAULT_INPUT_PRICE_PER_1M;
  if (MODEL_INPUT_PRICE_PER_1M[id] != null) {
    return MODEL_INPUT_PRICE_PER_1M[id];
  }
  let best: { key: string; price: number } | null = null;
  for (const [key, price] of Object.entries(MODEL_INPUT_PRICE_PER_1M)) {
    if (id.startsWith(key) && (!best || key.length > best.key.length)) {
      best = { key, price };
    }
  }
  return best ? best.price : DEFAULT_INPUT_PRICE_PER_1M;
}

/**
 * Estimate USD saved from `tokensSaved` INPUT tokens on `model`.
 * ESTIMATE ONLY (see MODEL_INPUT_PRICE_PER_1M). Rounded to 4 decimals.
 */
export function estimateSavingsUsd(tokensSaved: number, model: string): number {
  if (!Number.isFinite(tokensSaved) || tokensSaved <= 0) return 0;
  const usd = (tokensSaved / 1_000_000) * inputPricePer1M(model);
  return Math.round(usd * 10_000) / 10_000;
}
