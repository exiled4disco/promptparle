import { optimizePrompt } from "./optimizer";
import {
  getActiveProviderKey,
  isProviderRoutable,
  isValidProvider,
  touchProviderCredential,
} from "./providers";
import { getAdapter } from "./adapters";
import type { AdapterImage } from "./adapters/types";
import { normalizeAdapterImages } from "./adapters/types";
import { recordPromptRequest } from "./prompt-request";
import type { ProviderId } from "./constants";
import { normalizeCompressionLevel } from "./compression-level";
import { resolveSystemAndUser } from "./system-framing";
import {
  parsePreferredModelsJson,
  resolveModelForRequest,
} from "./models";

export type RunPromptInput = {
  userId: string;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  provider: string;
  model?: string;
  /** JSON map or object of provider→preferred model (portal user prefs) */
  preferredModels?: string | Record<string, string> | null;
  prompt: string;
  context?: string;
  /** Native system brief (0.14.12+). Not optimized; not stored in Before/After. */
  system?: string;
  /** Per-turn runtime note (tools/prep). Not optimized; not stored. */
  runtime?: string;
  profile?: string;
  /** 1 max fidelity … 5 max savings */
  compressionLevel?: number;
  optimizeOnly?: boolean;
  maxTokens?: number;
  /** Vision images (not optimized; forwarded to the model on full AI calls) */
  images?: AdapterImage[];
};

export type RunPromptSuccess = {
  ok: true;
  response?: string;
  optimizedPrompt: string;
  metadata: {
    original_tokens: number;
    optimized_tokens: number;
    token_reduction_percent: number;
    tokens_saved: number;
    expanded: boolean;
    provider: string;
    model: string;
    optimization_profile: string;
    compression_level: number;
    secrets_masked: boolean;
    secret_findings: string[];
    notes: string[];
    optimize_only: boolean;
    image_count?: number;
    strategy?: string;
    signals?: Record<string, number | string | boolean>;
    provider_request_id?: string;
    system_role?: boolean;
    cache_read_tokens?: number;
    cache_write_tokens?: number;
  };
};

export type RunPromptFailure = {
  ok: false;
  status: number;
  error: string;
  metadata?: RunPromptSuccess["metadata"];
};

export type RunPromptResult = RunPromptSuccess | RunPromptFailure;

/**
 * Shared optimize → (optional) provider call → usage row.
 * Used by desktop /api/v1/prompt and browser /api/chat.
 */
export async function runOptimizedPrompt(
  input: RunPromptInput
): Promise<RunPromptResult> {
  const provider = input.provider.toLowerCase();
  const profile = input.profile || "general";
  const compressionLevel = normalizeCompressionLevel(input.compressionLevel);
  const optimizeOnly = Boolean(input.optimizeOnly);

  if (!isValidProvider(provider)) {
    return { ok: false, status: 400, error: "Unknown provider" };
  }
  if (!isProviderRoutable(provider)) {
    return {
      ok: false,
      status: 400,
      error: `Provider '${provider}' is not available for routing yet`,
    };
  }

  const providerId = provider as ProviderId;
  const preferredMap =
    typeof input.preferredModels === "string"
      ? parsePreferredModelsJson(input.preferredModels)
      : input.preferredModels || null;
  const model = resolveModelForRequest({
    provider: providerId,
    requested: input.model,
    preferredModels: preferredMap,
  });
  const images = normalizeAdapterImages(input.images);

  // Separate product framing from user content (native system or baked [SYS] tags)
  const framed = resolveSystemAndUser({
    prompt: input.prompt,
    system: input.system,
    runtime: input.runtime,
  });

  const optimized = optimizePrompt({
    prompt: framed.userPrompt,
    context: input.context,
    profile,
    maxTokens: input.maxTokens,
    images,
    compressionLevel,
  });

  const notes = [...optimized.notes];
  if (framed.system || framed.runtime) {
    notes.push(
      framed.system
        ? "system role (native) — product brief not in user payload / usage Before"
        : "system framing stripped for storage"
    );
  }
  if (images.length > 0) {
    const hasImageNote = notes.some((n) => /image/i.test(n));
    if (!hasImageNote) {
      notes.push(
        `${images.length} image(s) attached — full pixels to vision; text channel got IMAGE SIGNAL focus brief`
      );
    }
  }

  const baseMeta = {
    original_tokens: optimized.originalTokens,
    optimized_tokens: optimized.optimizedTokens,
    token_reduction_percent: optimized.reductionPercent,
    tokens_saved: Math.max(
      0,
      optimized.originalTokens - optimized.optimizedTokens
    ),
    expanded: optimized.expanded,
    provider: providerId,
    model,
    optimization_profile: profile,
    compression_level: compressionLevel,
    secrets_masked: optimized.secretsMasked,
    secret_findings: optimized.secretFindings,
    notes,
    optimize_only: optimizeOnly,
    image_count: images.length,
    strategy: optimized.strategy,
    signals: optimized.signals,
    system_role: Boolean(framed.system || framed.runtime),
  };

  // Usage Before/After = user content only (never product [SYS] essay)
  const recordBase = {
    userId: input.userId,
    plan: input.plan,
    retentionPolicy: input.retentionPolicy,
    storePrompts: input.storePrompts,
    provider: providerId,
    model,
    optimizationProfile: profile,
    originalTokens: optimized.originalTokens,
    optimizedTokens: optimized.optimizedTokens,
    prompt: framed.storagePrompt,
    context: input.context,
    optimizedPrompt: optimized.optimizedPrompt,
  };

  if (optimizeOnly) {
    await recordPromptRequest({ ...recordBase, status: "completed" });
    return {
      ok: true,
      optimizedPrompt: optimized.optimizedPrompt,
      metadata: baseMeta,
    };
  }

  const cred = await getActiveProviderKey(input.userId, providerId);
  if (!cred) {
    return {
      ok: false,
      status: 400,
      error: `No active ${providerId} provider key. Add one under Providers.`,
      metadata: baseMeta,
    };
  }

  const adapter = getAdapter(providerId);
  try {
    const result = await adapter.complete({
      apiKey: cred.apiKey,
      model,
      prompt: optimized.optimizedPrompt,
      system: framed.system || undefined,
      runtime: framed.runtime || undefined,
      images: images.length > 0 ? images : undefined,
    });
    const usedModel = result.model || model;
    await touchProviderCredential(cred.credentialId);
    await recordPromptRequest({
      ...recordBase,
      model: usedModel,
      status: "completed",
    });
    return {
      ok: true,
      response: result.text,
      optimizedPrompt: optimized.optimizedPrompt,
      metadata: {
        ...baseMeta,
        model: usedModel,
        provider_request_id: result.providerRequestId,
        cache_read_tokens: result.rawUsage?.cacheReadTokens,
        cache_write_tokens: result.rawUsage?.cacheWriteTokens,
      },
    };
  } catch (providerErr) {
    const message =
      providerErr instanceof Error
        ? providerErr.message
        : "Provider request failed";
    await recordPromptRequest({
      ...recordBase,
      status: "failed",
      errorMessage: message,
    });
    return {
      ok: false,
      status: 502,
      error: message,
      metadata: baseMeta,
    };
  }
}
