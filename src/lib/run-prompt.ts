import { optimizePrompt } from "./optimizer";
import {
  defaultModelFor,
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

export type RunPromptInput = {
  userId: string;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  provider: string;
  model?: string;
  prompt: string;
  context?: string;
  profile?: string;
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
    secrets_masked: boolean;
    secret_findings: string[];
    notes: string[];
    optimize_only: boolean;
    image_count?: number;
    provider_request_id?: string;
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
  const model = input.model || defaultModelFor(providerId);
  const images = normalizeAdapterImages(input.images);

  const optimized = optimizePrompt({
    prompt: input.prompt,
    context: input.context,
    profile,
    maxTokens: input.maxTokens,
  });

  const notes = [...optimized.notes];
  if (images.length > 0) {
    notes.push(
      `${images.length} image(s) attached — passed to the model (not text-optimized)`
    );
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
    secrets_masked: optimized.secretsMasked,
    secret_findings: optimized.secretFindings,
    notes,
    optimize_only: optimizeOnly,
    image_count: images.length,
  };

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
    prompt: input.prompt,
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
