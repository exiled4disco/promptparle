import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { createFeedback } from "@/lib/feedback";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";

const schema = z.object({
  kind: z.enum(["bug", "suggest"]).default("suggest"),
  title: z.string().trim().min(3).max(200),
  body: z.string().trim().min(10).max(8000),
});

/** Desktop client: submit bug or suggestion with API key. */
export async function POST(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const ip = getClientIpFromHeaders(req.headers) || auth.clientIp || "unknown";
    const rl = checkRateLimit(
      `feedback:key:${auth.apiKeyId}`,
      RL.inviteRequestEmail.max,
      RL.inviteRequestEmail.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Need a short title and at least a few details." },
        { status: 400 }
      );
    }

    const row = await createFeedback({
      kind: parsed.data.kind,
      title: parsed.data.title,
      body: parsed.data.body,
      source: "desktop",
      userId: auth.user.id,
      email: auth.user.email,
      name: null,
      ip: ip !== "unknown" ? ip : null,
      userAgent: req.headers.get("user-agent"),
      headers: req.headers,
    });

    return NextResponse.json({
      ok: true,
      id: row.id,
      message: "Thanks. We received your feedback.",
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1 feedback POST", err);
    return NextResponse.json(
      { error: "Could not submit feedback" },
      { status: 500 }
    );
  }
}
