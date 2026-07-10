import { prisma } from "./db";
import {
  buildOriginalText,
  textsForStorage,
} from "./prompt-storage";

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
};

/** Persist a prompt request row with plan-capped before/after text. */
export async function recordPromptRequest(opts: RecordOpts) {
  const originalRaw = buildOriginalText(opts.prompt, opts.context);
  const stored = textsForStorage({
    plan: opts.plan,
    retentionPolicy: opts.retentionPolicy,
    storePrompts: opts.storePrompts,
    originalText: originalRaw,
    optimizedText: opts.optimizedPrompt,
  });

  return prisma.promptRequest.create({
    data: {
      userId: opts.userId,
      provider: opts.provider,
      model: opts.model || null,
      optimizationProfile: opts.optimizationProfile,
      originalTokens: opts.originalTokens,
      optimizedTokens: opts.optimizedTokens,
      status: opts.status,
      promptPreview: stored.promptPreview,
      originalText: stored.originalText,
      optimizedText: stored.optimizedText,
      originalTruncated: stored.originalTruncated,
      optimizedTruncated: stored.optimizedTruncated,
      errorMessage: opts.errorMessage ? opts.errorMessage.slice(0, 500) : null,
    },
  });
}
