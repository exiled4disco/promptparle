import { prisma } from "./db";

type RecordOpts = {
  userId: string;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  provider: string;
  model?: string | null;
  optimizationProfile: string;
  originalTokens: number;
  optimizedTokens: number;
  status: string;
  prompt: string;
  context?: string | null;
  optimizedPrompt: string;
  errorMessage?: string | null;
  /** Desktop chat title (safe metadata, not prompt body). */
  sessionTitle?: string | null;
  clientSessionId?: string | null;
};

/**
 * Persist usage stats only.
 * Never stores prompt or context bodies (product privacy default).
 * Session title / client session id are metadata only.
 */
export async function recordPromptRequest(opts: RecordOpts) {
  const sessionTitle = (opts.sessionTitle || "").trim().slice(0, 120) || null;
  const clientSessionId =
    (opts.clientSessionId || "").trim().slice(0, 80) || null;

  return prisma.promptRequest.create({
    data: {
      userId: opts.userId,
      provider: opts.provider,
      model: opts.model || null,
      optimizationProfile: opts.optimizationProfile,
      originalTokens: opts.originalTokens,
      optimizedTokens: opts.optimizedTokens,
      status: opts.status,
      // Stats-only: never persist prompt/context text
      promptPreview: null,
      originalText: null,
      optimizedText: null,
      originalTruncated: false,
      optimizedTruncated: false,
      sessionTitle,
      clientSessionId,
      errorMessage: opts.errorMessage ? opts.errorMessage.slice(0, 500) : null,
    },
  });
}
