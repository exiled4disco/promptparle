import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { optimizePrompt } from "@/lib/optimizer";
import { normalizeCompressionLevel } from "@/lib/compression-level";
import {
  coercePromptBody,
  formatZodDetails,
} from "@/lib/coerce-prompt-body";

const schema = z.object({
  prompt: z.string().min(1).max(500_000),
  context: z.string().max(2_000_000).optional(),
  optimization_profile: z.string().optional(),
  optimizationProfile: z.string().optional(),
  compression_level: z.number().int().min(1).max(5).optional(),
  compressionLevel: z.number().int().min(1).max(5).optional(),
  max_tokens: z.number().int().positive().optional(),
  maxTokens: z.number().int().positive().optional(),
});

/** Optimize only. no provider call. */
export async function POST(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const { checkRateLimit, RL, rateLimitResponse } = await import(
      "@/lib/rate-limit"
    );
    const rl = checkRateLimit(
      `v1:optimize:${auth.apiKeyId}`,
      RL.v1PromptKey.max,
      RL.v1PromptKey.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, {
        status: r.status,
        headers: r.headers,
      });
    }
    const body = coercePromptBody(await req.json());
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      const why = formatZodDetails(parsed.error);
      return NextResponse.json(
        { error: `Invalid request: ${why}`, details: parsed.error.flatten() },
        { status: 400 }
      );
    }

    const profile =
      parsed.data.optimization_profile ||
      parsed.data.optimizationProfile ||
      "general";
    const compressionLevel = normalizeCompressionLevel(
      parsed.data.compression_level ?? parsed.data.compressionLevel
    );
    const maxTokens = parsed.data.max_tokens ?? parsed.data.maxTokens;

    const result = optimizePrompt({
      prompt: parsed.data.prompt,
      context: parsed.data.context,
      profile,
      maxTokens,
      compressionLevel,
    });

    return NextResponse.json({
      optimized_prompt: result.optimizedPrompt,
      metadata: {
        original_tokens: result.originalTokens,
        optimized_tokens: result.optimizedTokens,
        token_reduction_percent: result.reductionPercent,
        expanded: result.expanded,
        tokens_saved: Math.max(
          0,
          result.originalTokens - result.optimizedTokens
        ),
        optimization_profile: result.profile,
        compression_level: compressionLevel,
        secrets_masked: result.secretsMasked,
        secret_findings: result.secretFindings,
        notes: result.notes,
        strategy: result.strategy,
        signals: result.signals,
      },
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/prompt/optimize error", err);
    return NextResponse.json({ error: "Optimize failed" }, { status: 500 });
  }
}
