import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import { runOptimizedPrompt } from "@/lib/run-prompt";
import { listProviderCredentials } from "@/lib/providers";
import { PROVIDERS } from "@/lib/constants";
import {
  coercePromptBody,
  formatZodDetails,
} from "@/lib/coerce-prompt-body";

const imageSchema = z.object({
  mediaType: z.string().optional(),
  media_type: z.string().optional(),
  dataBase64: z.string().optional(),
  data_base64: z.string().optional(),
  data: z.string().optional(),
  name: z.string().optional(),
});

const schema = z.object({
  provider: z.string().min(1),
  model: z.string().optional(),
  prompt: z.string().min(1).max(500_000),
  context: z.string().max(2_000_000).optional(),
  system: z.string().max(50_000).optional(),
  system_prompt: z.string().max(50_000).optional(),
  systemPrompt: z.string().max(50_000).optional(),
  runtime: z.string().max(20_000).optional(),
  runtime_note: z.string().max(20_000).optional(),
  runtimeNote: z.string().max(20_000).optional(),
  profile: z.string().optional(),
  /** 1 max fidelity … 5 max savings */
  compressionLevel: z.number().int().min(1).max(5).optional(),
  compression_level: z.number().int().min(1).max(5).optional(),
  optimizeOnly: z.boolean().optional(),
  optimize_only: z.boolean().optional(),
  images: z.array(imageSchema).max(8).optional(),
});

/** Browser chat — session cookie auth (not desktop API key). */
export async function POST(req: NextRequest) {
  try {
    const user = await requireUser();
    if (!user.emailVerifiedAt) {
      return NextResponse.json(
        { error: "Verify your email before chatting." },
        { status: 403 }
      );
    }

    const body = coercePromptBody(await req.json());
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      const why = formatZodDetails(parsed.error);
      return NextResponse.json(
        {
          error: `Invalid request: ${why}`,
          details: parsed.error.flatten(),
        },
        { status: 400 }
      );
    }

    const images = (parsed.data.images || []).map((img) => ({
      mediaType: img.mediaType || img.media_type || "image/png",
      dataBase64: img.dataBase64 || img.data_base64 || img.data || "",
      name: img.name,
    }));

    const result = await runOptimizedPrompt({
      userId: user.id,
      plan: user.plan,
      retentionPolicy: user.retentionPolicy,
      storePrompts: user.storePrompts,
      provider: parsed.data.provider,
      model: parsed.data.model,
      preferredModels: user.preferredModels,
      prompt: parsed.data.prompt,
      context: parsed.data.context,
      system:
        parsed.data.system ||
        parsed.data.system_prompt ||
        parsed.data.systemPrompt,
      runtime:
        parsed.data.runtime ||
        parsed.data.runtime_note ||
        parsed.data.runtimeNote,
      profile: parsed.data.profile,
      compressionLevel:
        parsed.data.compressionLevel ?? parsed.data.compression_level,
      optimizeOnly:
        parsed.data.optimizeOnly ?? parsed.data.optimize_only,
      images,
    });

    if (!result.ok) {
      return NextResponse.json(
        { error: result.error, metadata: result.metadata },
        { status: result.status }
      );
    }

    return NextResponse.json({
      response: result.response,
      optimized_prompt: result.optimizedPrompt,
      metadata: result.metadata,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("chat POST", err);
    return NextResponse.json({ error: "Chat failed" }, { status: 500 });
  }
}

/** Providers available for browser chat (configured keys only for routing). */
export async function GET() {
  try {
    const user = await requireUser();
    const creds = await listProviderCredentials(user.id);
    const active = new Set(
      creds.filter((c) => c.status === "active").map((c) => c.provider)
    );

    const providers = PROVIDERS.filter((p) => p.enabled && p.routing).map(
      (p) => ({
        id: p.id,
        name: p.name,
        defaultModel: p.defaultModel,
        configured: active.has(p.id),
      })
    );

    return NextResponse.json({ providers });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    return NextResponse.json({ error: "Failed" }, { status: 500 });
  }
}
