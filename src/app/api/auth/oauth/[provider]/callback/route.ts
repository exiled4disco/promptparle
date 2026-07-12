import { NextRequest, NextResponse } from "next/server";
import {
  completeOAuthLogin,
  isOAuthConfigured,
  type OAuthProvider,
  verifyOAuthState,
} from "@/lib/oauth";
import { setSessionCookie } from "@/lib/auth";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

const PROVIDERS: OAuthProvider[] = ["google", "github"];

function appUrl() {
  return (process.env.NEXT_PUBLIC_APP_URL || "http://localhost:3000").replace(
    /\/$/,
    ""
  );
}

function failRedirect(message: string) {
  const u = new URL(`${appUrl()}/login`);
  u.searchParams.set("error", message);
  return NextResponse.redirect(u);
}

export async function GET(
  req: NextRequest,
  ctx: { params: Promise<{ provider: string }> }
) {
  const { provider: raw } = await ctx.params;
  const provider = raw as OAuthProvider;
  if (!PROVIDERS.includes(provider) || !isOAuthConfigured(provider)) {
    return failRedirect(
      "This address is only a return URL after Google/GitHub login; it never shows Client IDs. Create an OAuth app at Google Cloud Console or GitHub → Settings → Developer settings, put the Client ID/Secret in the server .env, then restart. Until then use email and password."
    );
  }

  const err = req.nextUrl.searchParams.get("error");
  if (err) {
    return failRedirect("Sign-in was cancelled or denied.");
  }

  const code = req.nextUrl.searchParams.get("code");
  const state = req.nextUrl.searchParams.get("state");
  if (!code || !state) {
    return failRedirect("Invalid sign-in response.");
  }

  let next = "/app";
  try {
    const verified = await verifyOAuthState(state, provider);
    next = verified.next;
  } catch {
    return failRedirect("Sign-in session expired. Try again.");
  }

  try {
    const ip = getClientIpFromHeaders(req.headers);
    const { sessionToken } = await completeOAuthLogin({
      provider,
      code,
      ip,
      userAgent: req.headers.get("user-agent"),
    });
    await setSessionCookie(sessionToken);
    const dest = new URL(`${appUrl()}${next.startsWith("/") ? next : "/app"}`);
    return NextResponse.redirect(dest);
  } catch (e) {
    console.error("oauth callback error", e);
    const msg =
      e instanceof Error && e.message.includes("email")
        ? e.message
        : "Could not complete sign-in. Try again.";
    return failRedirect(msg);
  }
}
