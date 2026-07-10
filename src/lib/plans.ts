/**
 * Plan tiers control how much before/after prompt text is stored and shown.
 * Token metadata is always retained; full text is plan-capped.
 */

export type PlanId = "free" | "pro" | "team";

export type PlanLimits = {
  id: PlanId;
  label: string;
  /** Max characters stored/shown for original (before) text */
  originalChars: number;
  /** Max characters stored/shown for optimized (after) text */
  optimizedChars: number;
  /** Recent request rows returned in portal usage */
  historyLimit: number;
};

export const PLAN_LIMITS: Record<PlanId, PlanLimits> = {
  free: {
    id: "free",
    label: "Free",
    originalChars: 2_000,
    optimizedChars: 2_000,
    historyLimit: 25,
  },
  pro: {
    id: "pro",
    label: "Pro",
    originalChars: 50_000,
    optimizedChars: 50_000,
    historyLimit: 100,
  },
  team: {
    id: "team",
    label: "Team",
    originalChars: 200_000,
    optimizedChars: 200_000,
    historyLimit: 200,
  },
};

export function normalizePlan(plan: string | null | undefined): PlanId {
  const p = (plan || "free").toLowerCase();
  if (p === "pro" || p === "paid" || p === "plus") return "pro";
  if (p === "team" || p === "enterprise" || p === "business") return "team";
  return "free";
}

export function getPlanLimits(plan: string | null | undefined): PlanLimits {
  return PLAN_LIMITS[normalizePlan(plan)];
}
