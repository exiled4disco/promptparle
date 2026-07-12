import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { lookupPendingInviteByCode } from "@/lib/invitations";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

const schema = z.object({
  code: z.string().min(6).max(32),
});

/** Public: step 1 of registration. validate invitation code before account form. */
export async function POST(req: NextRequest) {
  const ip = getClientIpFromHeaders(req.headers) || "unknown";
  const rl = checkRateLimit(
    `invite-code-lookup:${ip}`,
    RL.loginIp.max,
    RL.loginIp.windowMs
  );
  if (!rl.ok) {
    const r = rateLimitResponse(rl.retryAfterSec);
    return NextResponse.json(r.body, { status: r.status, headers: r.headers });
  }

  const body = await req.json().catch(() => ({}));
  const parsed = schema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invitation code required (e.g. PP-XXXX-XXXX)" },
      { status: 400 }
    );
  }

  const result = await lookupPendingInviteByCode(parsed.data.code);
  if (!result.ok) {
    return NextResponse.json(
      { error: result.error },
      { status: result.status }
    );
  }

  return NextResponse.json({
    ok: true,
    email: result.email,
    email_masked: result.emailMasked,
    code: result.code,
    expires_at: result.expiresAt,
  });
}
