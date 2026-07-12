import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { createAndSendPasswordReset } from "@/lib/password-reset";
import { isMailConfigured } from "@/lib/mail";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

const schema = z.object({
  email: z.string().email().max(255),
});

/**
 * Always return the same success shape (no email enumeration).
 */
export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rlIp = checkRateLimit(
      `forgot:ip:${ip}`,
      RL.forgotIp.max,
      RL.forgotIp.windowMs
    );
    if (!rlIp.ok) {
      const r = rateLimitResponse(rlIp.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    if (!isMailConfigured()) {
      return NextResponse.json(
        {
          error:
            "Email delivery is not configured. Contact support to reset your password.",
        },
        { status: 503 }
      );
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Valid email required" }, { status: 400 });
    }

    const email = parsed.data.email.toLowerCase().trim();
    const rlEmail = checkRateLimit(
      `forgot:email:${email}`,
      RL.forgotEmail.max,
      RL.forgotEmail.windowMs
    );
    if (!rlEmail.ok) {
      // Still generic success to avoid probing. but throttle real sends
      return NextResponse.json({
        ok: true,
        message:
          "If an account exists for that email, we sent a reset link. Check your inbox.",
      });
    }

    try {
      await createAndSendPasswordReset(email);
    } catch (err) {
      console.error("password forgot send failed", err);
      return NextResponse.json(
        { error: "Could not send reset email. Try again later." },
        { status: 502 }
      );
    }

    await writeAudit({
      action: "auth.password_reset_request",
      ip,
      meta: { email },
    });

    return NextResponse.json({
      ok: true,
      message:
        "If an account exists for that email, we sent a reset link. Check your inbox (and spam).",
    });
  } catch (err) {
    console.error("password forgot error", err);
    return NextResponse.json({ error: "Request failed" }, { status: 500 });
  }
}
