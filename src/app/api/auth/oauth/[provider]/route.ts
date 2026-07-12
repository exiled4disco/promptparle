import { NextRequest, NextResponse } from "next/server";
import {
  createOAuthState,
  isOAuthConfigured,
  oauthAuthorizeUrl,
  type OAuthProvider,
} from "@/lib/oauth";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

const PROVIDERS: OAuthProvider[] = ["google", "github"];

export async function GET(
  req: NextRequest,
  ctx: { params: Promise<{ provider: string }> }
) {
  const { provider: raw } = await ctx.params;
  const provider = raw as OAuthProvider;
  if (!PROVIDERS.includes(provider)) {
    return NextResponse.json({ error: "Unknown provider" }, { status: 404 });
  }
  if (!isOAuthConfigured(provider)) {
    // Browser navigations (button/link) should land on login with a clear message,
    // not a raw JSON 503.
    const accept = req.headers.get("accept") || "";
    const wantsHtml = accept.includes("text/html");
    if (wantsHtml) {
      const app =
        (process.env.NEXT_PUBLIC_APP_URL || "https://promptparle.com").replace(
          /\/$/,
          ""
        );
      const u = new URL(`${app}/login`);
      u.searchParams.set(
        "error",
        `${provider === "google" ? "Google" : "GitHub"} login is off until the server has CLIENT_ID and CLIENT_SECRET from ${provider === "google" ? "Google Cloud Console → Credentials" : "GitHub → Settings → Developer settings → OAuth Apps"}. This site never generates those IDs. Use email for now.`
      );
      return NextResponse.redirect(u);
    }
    return NextResponse.json(
      {
        error: `${provider} sign-in is not configured on this server.`,
        code: "oauth_not_configured",
      },
      { status: 503 }
    );
  }

  const ip = getClientIpFromHeaders(req.headers) || "unknown";
  const rl = checkRateLimit(`oauth:${ip}`, RL.oauthIp.max, RL.oauthIp.windowMs);
  if (!rl.ok) {
    const r = rateLimitResponse(rl.retryAfterSec);
    return NextResponse.json(r.body, { status: r.status, headers: r.headers });
  }

  const next = req.nextUrl.searchParams.get("next") || "/app";
  try {
    const state = await createOAuthState({ provider, next });
    const url = oauthAuthorizeUrl(provider, state);
    return NextResponse.redirect(url);
  } catch (err) {
    console.error("oauth start error", err);
    return NextResponse.json(
      { error: "Could not start sign-in" },
      { status: 500 }
    );
  }
}
