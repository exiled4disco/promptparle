/**
 * Public flat pricing (product subscription).
 * AI provider token spend is always separate (BYOK).
 * Internal fair-use limits may still exist in plans.ts, they are not the price model.
 */

export type PublicPlanId = "free" | "pro" | "team";

export type PublicPlan = {
  id: PublicPlanId;
  name: string;
  tagline: string;
  priceMonthly: number;
  /** Yearly total charged (20% off vs 12× monthly). */
  priceYearly: number;
  /** Effective monthly when billed yearly. */
  priceYearlyPerMonth: number;
  seats: number;
  features: string[];
  cta: { href: string; label: string };
  highlighted?: boolean;
};

const YEARLY_DISCOUNT = 0.2;

function yearlyFromMonthly(monthly: number): {
  yearly: number;
  perMonth: number;
} {
  const yearly = Math.round(monthly * 12 * (1 - YEARLY_DISCOUNT) * 100) / 100;
  const perMonth = Math.round((yearly / 12) * 100) / 100;
  return { yearly, perMonth };
}

const proY = yearlyFromMonthly(29.99);
const teamY = yearlyFromMonthly(99.99);

export const YEARLY_DISCOUNT_PERCENT = 20;

export const PUBLIC_PLANS: PublicPlan[] = [
  {
    id: "free",
    name: "Free",
    tagline: "Try the gateway on real work.",
    priceMonthly: 0,
    priceYearly: 0,
    priceYearlyPerMonth: 0,
    seats: 1,
    features: [
      "1 desktop seat",
      "BYOK on your PC (OpenAI / Claude / Gemini / Grok)",
      "Local-first optimize + chat",
      "Context dial + profiles",
      "On-PC secret gate",
      "Invitation-only access",
    ],
    cta: { href: "/request-invite", label: "Request invitation" },
  },
  {
    id: "pro",
    name: "Pro",
    tagline: "For builders who live in the models.",
    priceMonthly: 29.99,
    priceYearly: proY.yearly,
    priceYearlyPerMonth: proY.perMonth,
    seats: 1,
    features: [
      "Everything in Free",
      "Priority product support",
      "All four providers on the PC",
      "More desktop flexibility",
      "Longer optional usage history",
      "Email support",
    ],
    cta: { href: "/request-invite", label: "Request Pro invite" },
    highlighted: true,
  },
  {
    id: "team",
    name: "Team",
    tagline: "Five seats. One shared gateway.",
    priceMonthly: 99.99,
    priceYearly: teamY.yearly,
    priceYearlyPerMonth: teamY.perMonth,
    seats: 5,
    features: [
      "Everything in Pro",
      "5 desktop seats included",
      "Shared invite workflow",
      "Team-friendly seat pool",
      "Admin-friendly usage view",
      "Priority onboarding",
    ],
    cta: { href: "/request-invite", label: "Request Team invite" },
  },
];

export function formatUsd(n: number): string {
  if (n === 0) return "$0";
  return n % 1 === 0 ? `$${n}` : `$${n.toFixed(2)}`;
}
