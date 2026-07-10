import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { optimizePrompt } from "@/lib/optimizer";
import {
  defaultModelFor,
  getActiveProviderKey,
  isProviderRoutable,
  isValidProvider,
  touchProviderCredential,
} from "@/lib/providers";
import { getAdapter } from "@/lib/adapters";
import { prisma } from "@/lib/db";
import type { ProviderId } from "@/lib/constants";

const schema = z.object({
  provider: z.string(),
  model: z.string().optional(),
  prompt: z.string().min(1).max(500_000),
  context: z.string().max(2_000_000).optional(),
  optimization_profile: z.string().optional(),
  optimizationProfile: z.string().optional(),
  return_metadata: z.boolean().optional(),
  returnMetadata: z.boolean().optional(),
  max_tokens: z.number().int().positive().optional(),
  maxTokens: z.number().int().positive().optional(),
  /** optimize only — do not call the AI provider */
  optimize_only: z.boolean().optional(),
  optimizeOnly: z.boolean().optional(),
});

export async function POST(req: NextRequest) {
  let userId: string | null = null;
  let provider = "unknown";
  let model: string | undefined;
  let profile = "general";
  let originalTokens = 0;
  let optimizedTokens = 0;

  try {
    const auth = await requireApiKey(req);
    userId = auth.user.id;

    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Invalid request", details: parsed.error.flatten() },
        { status: 400 }
      );
    }

    const data = parsed.data;
    provider = data.provider.toLowerCase();
    profile =
      data.optimization_profile ||
      data.optimizationProfile ||
      "general";
    const returnMetadata =
      data.return_metadata ?? data.returnMetadata ?? true;
    const optimizeOnly = data.optimize_only ?? data.optimizeOnly ?? false;
    const maxTokens = data.max_tokens ?? data.maxTokens;

    if (!isValidProvider(provider)) {
      return NextResponse.json({ error: "Unknown provider" }, { status: 400 });
    }
    if (!isProviderRoutable(provider)) {
      return NextResponse.json(
        { error: `Provider '${provider}' is not available for routing yet` },
        { status: 400 }
      );
    }

    const providerId = provider as ProviderId;
    model = data.model || defaultModelFor(providerId);

    const optimized = optimizePrompt({
      prompt: data.prompt,
      context: data.context,
      profile,
      maxTokens,
    });
    originalTokens = optimized.originalTokens;
    optimizedTokens = optimized.optimizedTokens;

    if (optimizeOnly) {
      await prisma.promptRequest.create({
        data: {
          userId: auth.user.id,
          provider: providerId,
          model,
          optimizationProfile: profile,
          originalTokens,
          optimizedTokens,
          status: "completed",
          promptPreview:
            auth.user.storePrompts && auth.user.retentionPolicy !== "none"
              ? optimized.optimizedPrompt.slice(0, 500)
              : null,
        },
      });

      return NextResponse.json({
        optimized_prompt: optimized.optimizedPrompt,
        metadata: returnMetadata
          ? {
              original_tokens: optimized.originalTokens,
              optimized_tokens: optimized.optimizedTokens,
              token_reduction_percent: optimized.reductionPercent,
              provider: providerId,
              model,
              optimization_profile: profile,
              secrets_masked: optimized.secretsMasked,
              secret_findings: optimized.secretFindings,
              notes: optimized.notes,
              optimize_only: true,
            }
          : undefined,
      });
    }

    const cred = await getActiveProviderKey(auth.user.id, providerId);
    if (!cred) {
      return NextResponse.json(
        {
          error: `No active ${providerId} provider key. Add one in the portal under Providers.`,
        },
        { status: 400 }
      );
    }

    const adapter = getAdapter(providerId);
    let aiText: string;
    let usedModel = model;
    let providerRequestId: string | undefined;

    try {
      const result = await adapter.complete({
        apiKey: cred.apiKey,
        model,
        prompt: optimized.optimizedPrompt,
      });
      aiText = result.text;
      usedModel = result.model || model;
      providerRequestId = result.providerRequestId;
      await touchProviderCredential(cred.credentialId);
    } catch (providerErr) {
      const message =
        providerErr instanceof Error
          ? providerErr.message
          : "Provider request failed";
      await prisma.promptRequest.create({
        data: {
          userId: auth.user.id,
          provider: providerId,
          model,
          optimizationProfile: profile,
          originalTokens,
          optimizedTokens,
          status: "failed",
          errorMessage: message.slice(0, 500),
        },
      });
      return NextResponse.json(
        {
          error: message,
          metadata: returnMetadata
            ? {
                original_tokens: optimized.originalTokens,
                optimized_tokens: optimized.optimizedTokens,
                token_reduction_percent: optimized.reductionPercent,
                provider: providerId,
                model,
                optimization_profile: profile,
                secrets_masked: optimized.secretsMasked,
              }
            : undefined,
        },
        { status: 502 }
      );
    }

    await prisma.promptRequest.create({
      data: {
        userId: auth.user.id,
        provider: providerId,
        model: usedModel,
        optimizationProfile: profile,
        originalTokens,
        optimizedTokens,
        status: "completed",
        promptPreview:
          auth.user.storePrompts && auth.user.retentionPolicy !== "none"
            ? data.prompt.slice(0, 500)
            : null,
      },
    });

    return NextResponse.json({
      response: aiText,
      metadata: returnMetadata
        ? {
            original_tokens: optimized.originalTokens,
            optimized_tokens: optimized.optimizedTokens,
            token_reduction_percent: optimized.reductionPercent,
            provider: providerId,
            model: usedModel,
            optimization_profile: profile,
            secrets_masked: optimized.secretsMasked,
            secret_findings: optimized.secretFindings,
            notes: optimized.notes,
            provider_request_id: providerRequestId,
          }
        : undefined,
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/prompt error", err);
    if (userId) {
      await prisma.promptRequest
        .create({
          data: {
            userId,
            provider,
            model: model || null,
            optimizationProfile: profile,
            originalTokens,
            optimizedTokens,
            status: "failed",
            errorMessage: "Internal error",
          },
        })
        .catch(() => {});
    }
    return NextResponse.json({ error: "Request failed" }, { status: 500 });
  }
}
