/**
 * Google + GitHub OAuth (authorization code). Minimal signup friction.
 * Credentials: GOOGLE_CLIENT_ID/SECRET, GITHUB_CLIENT_ID/SECRET.
 */

import { SignJWT, jwtVerify } from "jose";
import { prisma } from "./db";
import { createSession } from "./auth";
import { writeAudit } from "./audit";

export type OAuthProvider = "google" | "github";

const STATE_TTL_SEC = 600;

function appUrl() {
  return (process.env.NEXT_PUBLIC_APP_URL || "http://localhost:3000").replace(
    /\/$/,
    ""
  );
}

/** Exact redirect URI Google / GitHub must allow (no trailing slash). */
export function oauthRedirectUri(provider: OAuthProvider): string {
  const override =
    provider === "google"
      ? process.env.GOOGLE_REDIRECT_URI
      : process.env.GITHUB_REDIRECT_URI;
  if (override && override.trim()) {
    return override.trim().replace(/\/$/, "");
  }
  return `${appUrl()}/api/auth/oauth/${provider}/callback`;
}

function stateSecret() {
  const s = process.env.SESSION_SECRET || process.env.ENCRYPTION_KEY;
  if (!s || s.length < 16) {
    throw new Error("SESSION_SECRET (or ENCRYPTION_KEY) required for OAuth state");
  }
  return new TextEncoder().encode(s);
}

export function isOAuthConfigured(provider: OAuthProvider): boolean {
  if (provider === "google") {
    return Boolean(
      process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET
    );
  }
  return Boolean(
    process.env.GITHUB_CLIENT_ID && process.env.GITHUB_CLIENT_SECRET
  );
}

export function listConfiguredOAuthProviders(): OAuthProvider[] {
  const out: OAuthProvider[] = [];
  if (isOAuthConfigured("google")) out.push("google");
  if (isOAuthConfigured("github")) out.push("github");
  return out;
}

export async function createOAuthState(opts: {
  provider: OAuthProvider;
  next?: string;
}): Promise<string> {
  const next =
    opts.next && opts.next.startsWith("/") && !opts.next.startsWith("//")
      ? opts.next
      : "/app";
  return new SignJWT({
    p: opts.provider,
    n: next,
  })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime(`${STATE_TTL_SEC}s`)
    .setJti(crypto.randomUUID())
    .sign(stateSecret());
}

export async function verifyOAuthState(
  state: string,
  provider: OAuthProvider
): Promise<{ next: string }> {
  const { payload } = await jwtVerify(state, stateSecret());
  if (payload.p !== provider) {
    throw new Error("OAuth state provider mismatch");
  }
  const next =
    typeof payload.n === "string" && payload.n.startsWith("/")
      ? payload.n
      : "/app";
  return { next };
}

export function oauthAuthorizeUrl(
  provider: OAuthProvider,
  state: string
): string {
  const redirectUri = oauthRedirectUri(provider);
  if (provider === "google") {
    // Log once per process start path so operators can fix Google Console
    console.info(
      `[oauth] google redirect_uri=${redirectUri} (must match Google Cloud → Credentials → Authorized redirect URIs exactly)`
    );
    const u = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    u.searchParams.set("client_id", process.env.GOOGLE_CLIENT_ID!);
    u.searchParams.set("redirect_uri", redirectUri);
    u.searchParams.set("response_type", "code");
    u.searchParams.set("scope", "openid email profile");
    u.searchParams.set("state", state);
    u.searchParams.set("access_type", "online");
    u.searchParams.set("prompt", "select_account");
    return u.toString();
  }
  const u = new URL("https://github.com/login/oauth/authorize");
  u.searchParams.set("client_id", process.env.GITHUB_CLIENT_ID!);
  u.searchParams.set("redirect_uri", redirectUri);
  u.searchParams.set("scope", "read:user user:email");
  u.searchParams.set("state", state);
  return u.toString();
}

type OAuthProfile = {
  providerUserId: string;
  email: string;
  name: string | null;
  emailVerified: boolean;
};

async function exchangeGoogle(code: string): Promise<OAuthProfile> {
  const redirectUri = oauthRedirectUri("google");
  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: process.env.GOOGLE_CLIENT_ID!,
      client_secret: process.env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenRes.ok) {
    throw new Error("Google token exchange failed");
  }
  const tokenJson = (await tokenRes.json()) as { access_token?: string };
  if (!tokenJson.access_token) throw new Error("Google access token missing");

  const uiRes = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
    headers: { Authorization: `Bearer ${tokenJson.access_token}` },
  });
  if (!uiRes.ok) throw new Error("Google userinfo failed");
  const ui = (await uiRes.json()) as {
    sub?: string;
    email?: string;
    email_verified?: boolean;
    name?: string;
  };
  if (!ui.sub || !ui.email) throw new Error("Google profile incomplete");
  return {
    providerUserId: ui.sub,
    email: ui.email.toLowerCase().trim(),
    name: ui.name || null,
    emailVerified: Boolean(ui.email_verified),
  };
}

async function exchangeGitHub(code: string): Promise<OAuthProfile> {
  const redirectUri = oauthRedirectUri("github");
  const tokenRes = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      client_id: process.env.GITHUB_CLIENT_ID!,
      client_secret: process.env.GITHUB_CLIENT_SECRET!,
      code,
      redirect_uri: redirectUri,
    }),
  });
  if (!tokenRes.ok) throw new Error("GitHub token exchange failed");
  const tokenJson = (await tokenRes.json()) as {
    access_token?: string;
    error?: string;
  };
  if (!tokenJson.access_token) {
    throw new Error(tokenJson.error || "GitHub access token missing");
  }

  const userRes = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${tokenJson.access_token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "PromptParle",
    },
  });
  if (!userRes.ok) throw new Error("GitHub user failed");
  const user = (await userRes.json()) as {
    id?: number;
    login?: string;
    name?: string;
    email?: string | null;
  };
  if (!user.id) throw new Error("GitHub profile incomplete");

  let email = user.email?.toLowerCase().trim() || "";
  let emailVerified = false;

  const emailsRes = await fetch("https://api.github.com/user/emails", {
    headers: {
      Authorization: `Bearer ${tokenJson.access_token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "PromptParle",
    },
  });
  if (emailsRes.ok) {
    const emails = (await emailsRes.json()) as Array<{
      email: string;
      primary?: boolean;
      verified?: boolean;
    }>;
    const primary =
      emails.find((e) => e.primary && e.verified) ||
      emails.find((e) => e.verified) ||
      emails[0];
    if (primary) {
      email = primary.email.toLowerCase().trim();
      emailVerified = Boolean(primary.verified);
    }
  }

  if (!email) {
    throw new Error(
      "GitHub account has no email we can use. Make a verified email visible to OAuth apps."
    );
  }

  return {
    providerUserId: String(user.id),
    email,
    name: user.name || user.login || null,
    emailVerified: emailVerified || Boolean(user.email),
  };
}

export async function completeOAuthLogin(opts: {
  provider: OAuthProvider;
  code: string;
  ip?: string | null;
  userAgent?: string | null;
}): Promise<{ sessionToken: string; userId: string; isNew: boolean }> {
  if (!isOAuthConfigured(opts.provider)) {
    throw new Error(`${opts.provider} OAuth is not configured`);
  }

  const profile =
    opts.provider === "google"
      ? await exchangeGoogle(opts.code)
      : await exchangeGitHub(opts.code);

  if (!profile.emailVerified && opts.provider === "google") {
    // Google should always verify; refuse unverified
    throw new Error("Email is not verified with the identity provider");
  }

  // Existing OAuth link?
  const linked = await prisma.oAuthAccount.findUnique({
    where: {
      provider_providerUserId: {
        provider: opts.provider,
        providerUserId: profile.providerUserId,
      },
    },
    include: { user: true },
  });

  let user = linked?.user ?? null;
  let isNew = false;

  if (!user) {
    // Link by email if account already exists (password or other OAuth)
    user = await prisma.user.findUnique({ where: { email: profile.email } });
    if (user) {
      await prisma.oAuthAccount.create({
        data: {
          userId: user.id,
          provider: opts.provider,
          providerUserId: profile.providerUserId,
          email: profile.email,
        },
      });
      if (!user.emailVerifiedAt) {
        user = await prisma.user.update({
          where: { id: user.id },
          data: {
            emailVerifiedAt: new Date(),
            name: user.name || profile.name,
          },
        });
      }
    } else {
      isNew = true;
      user = await prisma.user.create({
        data: {
          email: profile.email,
          name: profile.name,
          passwordHash: null,
          plan: "free",
          emailVerifiedAt: new Date(),
          oauthAccounts: {
            create: {
              provider: opts.provider,
              providerUserId: profile.providerUserId,
              email: profile.email,
            },
          },
        },
      });
    }
  } else if (!user.emailVerifiedAt) {
    user = await prisma.user.update({
      where: { id: user.id },
      data: { emailVerifiedAt: new Date() },
    });
  }

  if (user.disabledAt) {
    throw new Error(
      "This account has been disabled. Contact support if you believe this is a mistake."
    );
  }

  const sessionToken = await createSession(user.id, {
    userAgent: opts.userAgent || undefined,
    ipAddress: opts.ip || undefined,
  });

  await writeAudit({
    action: "auth.oauth",
    userId: user.id,
    ip: opts.ip,
    meta: { provider: opts.provider, isNew },
  });

  return { sessionToken, userId: user.id, isNew };
}
