import { prisma } from "./db";

export async function getUsageSummary(userId: string) {
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
      take: 20,
      select: {
        id: true,
        provider: true,
        model: true,
        optimizationProfile: true,
        originalTokens: true,
        optimizedTokens: true,
        status: true,
        createdAt: true,
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
    recent,
    byProvider: byProvider.map((row) => ({
      provider: row.provider,
      count: row._count,
      originalTokens: row._sum.originalTokens ?? 0,
      optimizedTokens: row._sum.optimizedTokens ?? 0,
    })),
  };
}
