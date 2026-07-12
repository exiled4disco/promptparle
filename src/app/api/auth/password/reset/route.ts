import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { consumePasswordReset } from "@/lib/password-reset";
import { createSession, setSessionCookie } from "@/lib/auth";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

const schema = z.object({
  token: z.string().min(16).max(200),
  password: z.string().min(8).max(128),
});

export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `reset:ip:${ip}`,
      RL.resetIp.max,
      RL.resetIp.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Invalid reset request. Need a valid link and a password (8+ characters)." },
        { status: 400 }
      );
    }

    const result = await consumePasswordReset({
      rawToken: parsed.data.token,
      newPassword: parsed.data.password,
    });

    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: 400 });
    }

    // Sign them in with a fresh session (old ones already wiped)
    const sessionToken = await createSession(result.userId, {
      userAgent: req.headers.get("user-agent") || undefined,
      ipAddress: ip !== "unknown" ? ip : undefined,
      headers: req.headers,
    });
    await setSessionCookie(sessionToken);

    await writeAudit({
      action: "auth.password_reset",
      userId: result.userId,
      ip,
    });

    return NextResponse.json({ ok: true });
  } catch (err) {
    console.error("password reset error", err);
    return NextResponse.json({ error: "Reset failed" }, { status: 500 });
  }
}
