import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import {
  MAX_SAVINGS_ITEMS,
  recordToolSavings,
} from "@/lib/tool-savings";

/**
 * Per-tool token-savings bridge (desktop → portal).
 *
 * The desktop client is local-first and computes token savings on the PC.
 * It POSTs the aggregate, privacy-safe rollup here for portal display.
 *
 * PRIVACY: aggregate counts + labels ONLY. This endpoint neither accepts nor
 * stores any prompt/context/response text. Unknown tools are dropped server-side.
 */
const itemSchema = z.object({
  tool: z.string().min(1).max(40),
  provider: z.string().min(1).max(40),
  chars_saved: z.number().int().min(0).max(2_000_000_000),
  occurrences: z.number().int().min(0).max(1_000_000),
});

const schema = z.object({
  day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "day must be YYYY-MM-DD (UTC)"),
  items: z.array(itemSchema).max(MAX_SAVINGS_ITEMS),
});

export async function POST(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);

    const { checkRateLimit, RL, rateLimitResponse } = await import(
      "@/lib/rate-limit"
    );
    const rl = checkRateLimit(
      `v1:savings:${auth.apiKeyId}`,
      RL.v1GeneralKey.max,
      RL.v1GeneralKey.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(
        rl.retryAfterSec,
        "Desktop API rate limit exceeded for savings. Retry shortly."
      );
      return NextResponse.json(r.body, {
        status: r.status,
        headers: r.headers,
      });
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        {
          error:
            "Invalid body. Need { day: YYYY-MM-DD, items: [{ tool, provider, chars_saved, occurrences }] }.",
          details: parsed.error.flatten(),
        },
        { status: 400 }
      );
    }

    const { stored } = await recordToolSavings({
      userId: auth.user.id,
      day: parsed.data.day,
      items: parsed.data.items.map((it) => ({
        tool: it.tool,
        provider: it.provider,
        charsSaved: it.chars_saved,
        occurrences: it.occurrences,
      })),
    });

    return NextResponse.json({ ok: true, stored });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/desktop/savings", err);
    return NextResponse.json(
      { error: "Failed to record tool savings" },
      { status: 500 }
    );
  }
}
