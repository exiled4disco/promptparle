import { NextRequest, NextResponse } from "next/server";
import { validateInviteCode } from "@/lib/invitations";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

/**
 * Public (rate-limited): desktop installer validates invitation code.
 * GET ?code=PP-XXXX-XXXX  or  POST { code }
 */
export async function GET(req: NextRequest) {
  return handle(req, req.nextUrl.searchParams.get("code") || "");
}

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}));
  const code =
    typeof body.code === "string"
      ? body.code
      : typeof body.invitation_code === "string"
        ? body.invitation_code
        : "";
  return handle(req, code);
}

async function handle(req: NextRequest, code: string) {
  const ip = getClientIpFromHeaders(req.headers) || "unknown";
  const rl = checkRateLimit(
    `invite-validate:${ip}`,
    RL.loginIp.max,
    RL.loginIp.windowMs
  );
  if (!rl.ok) {
    const r = rateLimitResponse(rl.retryAfterSec);
    return NextResponse.json(r.body, { status: r.status, headers: r.headers });
  }

  if (!code.trim()) {
    return NextResponse.json({ error: "Invitation code required" }, { status: 400 });
  }

  const result = await validateInviteCode(code);
  if (!result.ok) {
    return NextResponse.json({ ok: false, error: result.error }, { status: 400 });
  }

  return NextResponse.json({
    ok: true,
    status: result.status,
    email_masked: result.emailMasked,
    portal_url: result.portalUrl,
    steps: result.steps,
  });
}
