import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { runAgentStep } from "@/lib/run-agent";

const toolCallSchema = z.object({
  id: z.string(),
  type: z.literal("function").optional().default("function"),
  function: z.object({
    name: z.string(),
    arguments: z.string(),
  }),
});

const messageSchema = z.object({
  role: z.enum(["system", "user", "assistant", "tool"]),
  content: z.string().nullable().optional(),
  name: z.string().optional(),
  tool_call_id: z.string().optional(),
  tool_calls: z.array(toolCallSchema).optional(),
});

const toolDefSchema = z.object({
  type: z.literal("function"),
  function: z.object({
    name: z.string().min(1).max(128),
    description: z.string().max(4000).optional(),
    parameters: z.record(z.string(), z.unknown()).optional(),
  }),
});

const schema = z.object({
  provider: z.string().min(1),
  model: z.string().optional(),
  messages: z.array(messageSchema).min(1).max(200),
  tools: z.array(toolDefSchema).max(64).optional(),
  tool_choice: z.enum(["auto", "none", "required"]).optional(),
  toolChoice: z.enum(["auto", "none", "required"]).optional(),
  max_tokens: z.number().int().positive().max(128000).optional(),
  maxTokens: z.number().int().positive().max(128000).optional(),
  temperature: z.number().min(0).max(2).optional(),
  include_raw: z.boolean().optional(),
  includeRaw: z.boolean().optional(),
});

/**
 * POST /api/v1/agent
 * Pass-through multi-provider agent step (native tools).
 * Desktop runs the multi-round tool loop; this endpoint is one model call.
 * No prompt optimization.
 */
export async function POST(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        {
          error: "Invalid agent request",
          details: parsed.error.flatten(),
        },
        { status: 400 }
      );
    }

    const data = parsed.data;
    const result = await runAgentStep({
      userId: auth.user.id,
      plan: auth.user.plan,
      retentionPolicy: auth.user.retentionPolicy,
      storePrompts: auth.user.storePrompts,
      provider: data.provider,
      model: data.model,
      messages: data.messages.map((m) => ({
        role: m.role,
        content: m.content ?? null,
        name: m.name,
        tool_call_id: m.tool_call_id,
        tool_calls: m.tool_calls?.map((tc) => ({
          id: tc.id,
          type: "function" as const,
          function: {
            name: tc.function.name,
            arguments: tc.function.arguments,
          },
        })),
      })),
      tools: data.tools,
      toolChoice: data.tool_choice || data.toolChoice || "auto",
      maxTokens: data.max_tokens || data.maxTokens,
      temperature: data.temperature,
      includeRaw: data.include_raw ?? data.includeRaw ?? true,
    });

    if (!result.ok) {
      return NextResponse.json(
        { error: result.error, ok: false },
        { status: result.status }
      );
    }

    return NextResponse.json(result);
  } catch (e) {
    if (e instanceof V1AuthError) {
      return NextResponse.json({ error: e.message }, { status: e.status || 401 });
    }
    const msg = e instanceof Error ? e.message : String(e);
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}
