import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { getSessionUser } from "@/lib/auth";
import { createFeedback } from "@/lib/feedback";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { writeAudit } from "@/lib/audit";

/**
 * Public contact form. Stores as a FeedbackSubmission(kind="contact") so it lands
 * in the same admin message manager as bug/suggest, and notifies admins by email
 * (reply-to = sender). No auth required; name + email + message.
 */
const schema = z.object({
  name: z.string().trim().min(1).max(120),
  email: z.string().trim().email().max(200),
  subject: z.string().trim().max(200).optional().nullable(),
  message: z.string().trim().min(10).max(8000),
  /** Honeypot — bots fill this; humans never see it. */
  website: z.string().max(200).optional().nullable(),
});

export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `contact:ip:${ip}`,
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
        { error: "Please provide your name, a valid email, and a message (10+ characters)." },
        { status: 400 }
      );
    }
    // Honeypot tripped → pretend success, drop silently.
    if ((parsed.data.website || "").trim()) {
      return NextResponse.json({ ok: true, message: "Thanks — we'll be in touch." });
    }

    const user = await getSessionUser();
    const title = (parsed.data.subject || "").trim() || "Contact message";

    await createFeedback({
      kind: "contact",
      title,
      body: parsed.data.message,
      source: "portal",
      userId: user?.id,
      email: parsed.data.email,
      name: parsed.data.name,
      ip: ip !== "unknown" ? ip : null,
      userAgent: req.headers.get("user-agent"),
      headers: req.headers,
    });

    await writeAudit({
      action: "contact.submitted",
      userId: user?.id,
      ip: ip !== "unknown" ? ip : null,
      meta: { email: parsed.data.email },
    });

    return NextResponse.json({
      ok: true,
      message: "Thanks — your message was sent. We'll reply to your email.",
    });
  } catch (err) {
    console.error("contact", err);
    return NextResponse.json(
      { error: "Could not send your message. Please try again." },
      { status: 500 }
    );
  }
}
