import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { getSessionUser } from "@/lib/auth";
import { createFeedback } from "@/lib/feedback";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { writeAudit } from "@/lib/audit";

const schema = z.object({
  kind: z.enum(["bug", "suggest"]).default("suggest"),
  title: z.string().trim().min(3).max(200),
  body: z.string().trim().min(10).max(8000),
  /** Honeypot */
  website: z.string().max(200).optional().nullable(),
});

/**
 * Portal (session optional): submit bug or suggestion.
 * Signed-in users attach identity automatically.
 */
export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `feedback:ip:${ip}`,
      RL.inviteRequestIp.max,
      RL.inviteRequestIp.windowMs
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
    if ((parsed.data.website || "").trim()) {
      return NextResponse.json({ ok: true, message: "Thanks." });
    }

    const user = await getSessionUser();
    const row = await createFeedback({
      kind: parsed.data.kind,
      title: parsed.data.title,
      body: parsed.data.body,
      source: "portal",
      userId: user?.id,
      email: user?.email,
      name: user?.name,
      ip: ip !== "unknown" ? ip : null,
      userAgent: req.headers.get("user-agent"),
      headers: req.headers,
    });

    await writeAudit({
      action: "settings.update",
      userId: user?.id,
      ip,
      meta: {
        kind: "feedback",
        feedbackId: row.id,
        feedbackKind: row.kind,
      },
    });

    return NextResponse.json({
      ok: true,
      id: row.id,
      message: "Thanks. We received your feedback.",
    });
  } catch (err) {
    console.error("feedback POST", err);
    return NextResponse.json(
      { error: "Could not submit feedback. Try again later." },
      { status: 500 }
    );
  }
}
