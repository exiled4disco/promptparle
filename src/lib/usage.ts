import { prisma } from "./db";
import { getPlanLimits } from "./plans";
import { planUpgradeHint } from "./prompt-storage";

export type UsageSummaryOpts = {
  plan?: string;
  /** Include recent request rows (default true). Desktop modals can set false. */
  includeRecent?: boolean;
  /** Cap recent rows (default plan historyLimit). Desktop uses a small cap. */
  recentLimit?: number;
  /** Include by-provider rollup (default true). */
  includeByProvider?: boolean;
  /**
   * When true, recent rows include stored prompt text (portal history only).
   * Desktop / modal views should leave this false to cut DB read size.
   */
  includePromptBodies?: boolean;
};

export async function getUsageSummary(
  userId: string,
  opts?: UsageSummaryOpts
) {
  const includeRecent = opts?.includeRecent !== false;
  const includeByProvider = opts?.includeByProvider !== false;
  const includePromptBodies = opts?.includePromptBodies === true;

  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: {
      plan: true,
      storePrompts: true,
      retentionPolicy: true,
    },
  });

  const effectivePlan = user?.plan || opts?.plan || "free";
  const limits = getPlanLimits(effectivePlan);
  const recentTake = Math.min(
    Math.max(0, opts?.recentLimit ?? limits.historyLimit),
    limits.historyLimit
  );

  // Stats always include hidden-from-history rows (delete history ≠ wipe totals).
  const totalsPromise = prisma.promptRequest.aggregate({
    where: { userId, status: "completed" },
    _sum: {
      originalTokens: true,
      optimizedTokens: true,
    },
    _count: true,
  });

  // Request History UI only: soft-hidden rows stay out of the list.
  const recentPromise = includeRecent
    ? prisma.promptRequest.findMany({
        where: { userId, historyHiddenAt: null },
        orderBy: { createdAt: "desc" },
        take: recentTake,
        // Stats + session titles only (prompt bodies no longer stored)
        select: {
          id: true,
          provider: true,
          model: true,
          optimizationProfile: true,
          originalTokens: true,
          optimizedTokens: true,
          status: true,
          createdAt: true,
          promptPreview: true,
          sessionTitle: true,
          clientSessionId: true,
          errorMessage: true,
          ...(includePromptBodies
            ? {
                originalText: true,
                optimizedText: true,
                originalTruncated: true,
                optimizedTruncated: true,
              }
            : {}),
        },
      })
    : Promise.resolve([]);

  const byProviderPromise = includeByProvider
    ? prisma.promptRequest.groupBy({
        by: ["provider"],
        where: { userId, status: "completed" },
        _sum: {
          originalTokens: true,
          optimizedTokens: true,
        },
        _count: true,
      })
    : Promise.resolve([]);

  const [totals, recent, byProvider] = await Promise.all([
    totalsPromise,
    recentPromise,
    byProviderPromise,
  ]);

  const original = totals._sum.originalTokens ?? 0;
  const optimized = totals._sum.optimizedTokens ?? 0;
  const saved = Math.max(0, original - optimized);
  const reductionPercent =
    original > 0 ? Math.round((saved / original) * 100) : 0;

  return {
    requestCount: totals._count,
    originalTokens: original,
    optimizedTokens: optimized,
    tokensSaved: saved,
    reductionPercent,
    plan: effectivePlan,
    planLimits: {
      id: limits.id,
      label: limits.label,
      originalChars: limits.originalChars,
      optimizedChars: limits.optimizedChars,
      historyLimit: limits.historyLimit,
      dailyRequests: limits.dailyRequests,
      maxProviders: limits.maxProviders,
    },
    storePrompts: false, // product is stats-only
    retentionPolicy: user?.retentionPolicy ?? "7d",
    upgradeHint: planUpgradeHint(limits),
    recent: recent.map((row) => {
      const rowSaved = Math.max(0, row.originalTokens - row.optimizedTokens);
      const pct =
        row.originalTokens > 0
          ? Math.round((rowSaved / row.originalTokens) * 100)
          : 0;
      return {
        ...row,
        reductionPercent: pct,
        tokensSaved: rowSaved,
        hasCompare: false,
        sessionTitle:
          "sessionTitle" in row
            ? (row as { sessionTitle?: string | null }).sessionTitle ?? null
            : null,
        clientSessionId:
          "clientSessionId" in row
            ? (row as { clientSessionId?: string | null }).clientSessionId ??
              null
            : null,
      };
    }),
    byProvider: byProvider.map((row) => ({
      provider: row.provider,
      count: row._count,
      originalTokens: row._sum.originalTokens ?? 0,
      optimizedTokens: row._sum.optimizedTokens ?? 0,
    })),
  };
}
