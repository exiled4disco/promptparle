/**
 * Plan tiers — product subscription is flat (see pricing.ts).
 * These limits are fair-use / product shape, not the public price model.
 * Token metadata is always retained; prompt bodies are not stored (stats-only).
 */

export type PlanId = "free" | "pro" | "team";

export type PlanLimits = {
  id: PlanId;
  label: string;
  /** Max characters stored/shown for original (before) text (legacy field; bodies not stored) */
  originalChars: number;
  /** Max characters stored/shown for optimized (after) text (legacy field; bodies not stored) */
  optimizedChars: number;
  /** Recent request rows returned in portal usage */
  historyLimit: number;
  /**
   * Soft fair-use cap on completed API / chat requests per UTC day.
   * Not the public pricing model — subscriptions are flat monthly/yearly.
   */
  dailyRequests: number;
  /** Max AI provider credentials (carriers) the account may attach */
  maxProviders: number;
  /**
   * Max concurrent desktop clients (local UI) with recent heartbeat.
   * Team plan = 5 seats (matches public Team of 5 pricing).
   */
  maxDesktopClients: number;
};

export const PLAN_LIMITS: Record<PlanId, PlanLimits> = {
  free: {
    id: "free",
    label: "Free",
    originalChars: 200_000,
    optimizedChars: 200_000,
    historyLimit: 200,
    dailyRequests: 100_000,
    maxProviders: 4,
    maxDesktopClients: 25,
  },
  // 0.32.0: PromptParle is free for everyone. There is no paid tier and no paywall —
  // the work runs on the user's PC (BYOK), so the portal has no per-request server cost
  // to throttle for money. These "pro"/"team" keys are retained only so existing DB
  // `plan` values and importers keep resolving; every tier now gets the SAME free limits.
  // Each desktop still needs its own license key (maxDesktopClients + heartbeat seat logic).
  pro: {
    id: "pro",
    label: "Free",
    originalChars: 200_000,
    optimizedChars: 200_000,
    historyLimit: 200,
    dailyRequests: 100_000,
    maxProviders: 4,
    maxDesktopClients: 25,
  },
  team: {
    id: "team",
    label: "Free",
    originalChars: 200_000,
    optimizedChars: 200_000,
    historyLimit: 200,
    dailyRequests: 100_000,
    maxProviders: 4,
    maxDesktopClients: 25,
  },
};

/** Heartbeat window: clients not seen within this interval free a seat. */
export const DESKTOP_CLIENT_ACTIVE_MS = 2 * 60 * 1000;

export function normalizePlan(plan: string | null | undefined): PlanId {
  const p = (plan || "free").toLowerCase();
  if (p === "pro" || p === "paid" || p === "plus") return "pro";
  if (p === "team" || p === "enterprise" || p === "business") return "team";
  return "free";
}

export function getPlanLimits(plan: string | null | undefined): PlanLimits {
  return PLAN_LIMITS[normalizePlan(plan)];
}
