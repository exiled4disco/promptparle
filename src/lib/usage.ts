import { prisma } from "./db";
import { getPlanLimits } from "./plans";
import { planUpgradeHint } from "./prompt-storage";

export async function getUsageSummary(
  userId: string,
  opts?: { plan?: string }
) {
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

  const [totals, recent, byProvider] = await Promise.all([
    prisma.promptRequest.aggregate({
      where: { userId, status: "completed" },
      _sum: {
        originalTokens: true,
        optimizedTokens: true,
      },
      _count: true,
    }),
    prisma.promptRequest.findMany({
      where: { userId },
      orderBy: { createdAt: "desc" },
      take: limits.historyLimit,
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
        originalText: true,
        optimizedText: true,
        originalTruncated: true,
        optimizedTruncated: true,
        errorMessage: true,
      },
    }),
    prisma.promptRequest.groupBy({
      by: ["provider"],
      where: { userId, status: "completed" },
      _sum: {
        originalTokens: true,
        optimizedTokens: true,
      },
      _count: true,
    }),
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
    },
    storePrompts: user?.storePrompts ?? true,
    retentionPolicy: user?.retentionPolicy ?? "7d",
    upgradeHint: planUpgradeHint(limits),
    recent: recent.map((row) => {
      const rowSaved = Math.max(0, row.originalTokens - row.optimizedTokens);
      const pct =
        row.originalTokens > 0
          ? Math.round((rowSaved / row.originalTokens) * 100)
          : 0;
      const hasCompare = Boolean(row.originalText || row.optimizedText);
      return {
        ...row,
        reductionPercent: pct,
        tokensSaved: rowSaved,
        hasCompare,
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
