import { prisma } from "./db";

/**
 * Soft-hide request history so token stats stay intact.
 * Clears stored prompt bodies (privacy) but keeps token counts / status / provider.
 */
export async function hideUsageHistoryRows(opts: {
  userId: string;
  /** One row id, or omit with all=true */
  id?: string;
  all?: boolean;
}): Promise<{ hidden: number }> {
  const now = new Date();
  const data = {
    historyHiddenAt: now,
    // Drop prompt text when user deletes history; stats fields untouched
    promptPreview: null,
    originalText: null,
    optimizedText: null,
    errorMessage: null,
  };

  if (opts.all) {
    const result = await prisma.promptRequest.updateMany({
      where: { userId: opts.userId, historyHiddenAt: null },
      data,
    });
    return { hidden: result.count };
  }

  if (!opts.id) {
    return { hidden: 0 };
  }

  const result = await prisma.promptRequest.updateMany({
    where: {
      id: opts.id,
      userId: opts.userId,
      historyHiddenAt: null,
    },
    data,
  });
  return { hidden: result.count };
}
