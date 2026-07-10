import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { optimizePrompt } from "@/lib/optimizer";

const schema = z.object({
  prompt: z.string().min(1).max(500_000),
  context: z.string().max(2_000_000).optional(),
  optimization_profile: z.string().optional(),
  optimizationProfile: z.string().optional(),
  max_tokens: z.number().int().positive().optional(),
  maxTokens: z.number().int().positive().optional(),
});

/** Optimize only — no provider call. */
export async function POST(req: NextRequest) {
  try {
    await requireApiKey(req);
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid request" }, { status: 400 });
    }

    const profile =
      parsed.data.optimization_profile ||
      parsed.data.optimizationProfile ||
      "general";
    const maxTokens = parsed.data.max_tokens ?? parsed.data.maxTokens;

    const result = optimizePrompt({
      prompt: parsed.data.prompt,
      context: parsed.data.context,
      profile,
      maxTokens,
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
        secrets_masked: result.secretsMasked,
        secret_findings: result.secretFindings,
        notes: result.notes,
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
