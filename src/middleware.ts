import { NextRequest, NextResponse } from "next/server";

const SESSION_COOKIE = "pp_session";

/** Security headers for all matched routes (and extended matcher below). */
function withSecurityHeaders(res: NextResponse): NextResponse {
  res.headers.set("X-Content-Type-Options", "nosniff");
  res.headers.set("X-Frame-Options", "DENY");
  res.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  res.headers.set(
    "Permissions-Policy",
    "camera=(), microphone=(), geolocation=(), payment=()"
  );
  res.headers.set(
    "Content-Security-Policy",
    [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
    ].join("; ")
  );
  // HSTS only when the request is already HTTPS (prod behind TLS terminator)
  const proto =
    res.headers.get("x-forwarded-proto") ||
    // next may not set this on response; check request in caller
    "";
  if (proto === "https" || process.env.NODE_ENV === "production") {
    res.headers.set(
      "Strict-Transport-Security",
      "max-age=31536000; includeSubDomains; preload"
    );
  }
  return res;
}

export function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl;
  const hasSession = Boolean(req.cookies.get(SESSION_COOKIE)?.value);

  // Soft gate for app UI: full validation happens in server components / API
  if (pathname.startsWith("/app") && !hasSession) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", pathname);
    return withSecurityHeaders(NextResponse.redirect(url));
  }

  if (
    (pathname === "/login" ||
      pathname === "/register" ||
      pathname === "/forgot-password") &&
    hasSession
  ) {
    const url = req.nextUrl.clone();
    url.pathname = "/app";
    return withSecurityHeaders(NextResponse.redirect(url));
  }

  const res = NextResponse.next();
  // Prefer request proto for HSTS decision
  const proto =
    req.headers.get("x-forwarded-proto") ||
    req.nextUrl.protocol.replace(":", "");
  if (proto === "https" || process.env.NODE_ENV === "production") {
    res.headers.set(
      "Strict-Transport-Security",
      "max-age=31536000; includeSubDomains; preload"
    );
  }
  return withSecurityHeaders(res);
}

export const config = {
  // Do NOT match pure marketing pages (/, /faq, /install, /request-invite):
  // they stay statically cacheable for crawlers. App/auth/API still get headers.
  matcher: [
    "/app/:path*",
    "/login",
    "/register",
    "/verify-email",
    "/forgot-password",
    "/reset-password",
    "/invite/:path*",
    "/api/:path*",
  ],
};
