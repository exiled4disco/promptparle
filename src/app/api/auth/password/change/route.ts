import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { cookies } from "next/headers";
import { AuthError, requireUser } from "@/lib/auth";
import { changePasswordForUser } from "@/lib/password-reset";
import { sha256 } from "@/lib/crypto";
import { SESSION_COOKIE } from "@/lib/constants";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

const schema = z.object({
  currentPassword: z.string().max(128).optional().nullable(),
  newPassword: z.string().min(8).max(128),
});

export async function POST(req: NextRequest) {
  try {
    const user = await requireUser();
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `changepw:ip:${ip}:${user.id}`,
      RL.changePasswordIp.max,
      RL.changePasswordIp.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "New password must be 8-128 characters" },
        { status: 400 }
      );
    }

    const cookieStore = await cookies();
    const sessionToken = cookieStore.get(SESSION_COOKIE)?.value || null;
    const keepHash = sessionToken ? sha256(sessionToken) : null;

    const result = await changePasswordForUser({
      userId: user.id,
      currentPassword: parsed.data.currentPassword,
      newPassword: parsed.data.newPassword,
      keepSessionTokenHash: keepHash,
    });

    if (!result.ok) {
      return NextResponse.json(
        { error: result.error },
        { status: result.status }
      );
    }

    await writeAudit({
      action: "auth.password_change",
      userId: user.id,
      ip,
    });

    return NextResponse.json({
      ok: true,
      message: "Password updated. Other sessions were signed out.",
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("password change error", err);
    return NextResponse.json({ error: "Could not change password" }, { status: 500 });
  }
}
