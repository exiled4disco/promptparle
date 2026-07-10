import { authenticateApiKey } from "./api-keys";
import { prisma } from "./db";
import {
  getClientIpFromHeaders,
  isIpAllowed,
} from "./ip-allowlist";

export type V1User = {
  id: string;
  email: string;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  emailVerifiedAt: Date | null;
};

export type V1Auth = {
  user: V1User;
  apiKeyId: string;
  clientIp: string | null;
};

type HeaderSource = { headers: Headers };

/**
 * Authenticate desktop API key from Authorization: Bearer pp_live_...
 * or X-PromptParle-Key header.
 * Enforces user.allowedIps when set (empty = unrestricted).
 * Browser session/Settings are NOT gated here (lockout-safe).
 */
export async function requireApiKey(req: HeaderSource): Promise<V1Auth> {
  const header =
    req.headers.get("authorization") ||
    req.headers.get("Authorization") ||
    "";
  let raw = "";
  if (header.toLowerCase().startsWith("bearer ")) {
    raw = header.slice(7).trim();
  } else {
    raw =
      req.headers.get("x-promptparle-key") ||
      req.headers.get("X-PromptParle-Key") ||
      "";
  }

  if (!raw || !raw.startsWith("pp_live_")) {
    throw new V1AuthError(
      "Missing or invalid API key. Use Authorization: Bearer pp_live_..."
    );
  }

  const auth = await authenticateApiKey(raw);
  if (!auth) {
    throw new V1AuthError("Invalid or revoked API key");
  }

  // Ensure user is email-verified + load allowlist
  const user = await prisma.user.findUnique({
    where: { id: auth.user.id },
    select: {
      id: true,
      email: true,
      plan: true,
      retentionPolicy: true,
      storePrompts: true,
      emailVerifiedAt: true,
      allowedIps: true,
    },
  });

  if (!user || !user.emailVerifiedAt) {
    throw new V1AuthError("Account email is not verified", 403);
  }

  const clientIp = getClientIpFromHeaders(req.headers);
  if (!isIpAllowed(clientIp, user.allowedIps)) {
    throw new V1AuthError(
      `API key blocked: your IP (${clientIp || "unknown"}) is not on this account's allowlist. Update Settings → API IP allowlist from the portal (browser session is not gated).`,
      403
    );
  }

  return {
    user: {
      id: user.id,
      email: user.email,
      plan: user.plan,
      retentionPolicy: user.retentionPolicy,
      storePrompts: user.storePrompts,
      emailVerifiedAt: user.emailVerifiedAt,
    },
    apiKeyId: auth.key.id,
    clientIp,
  };
}

export class V1AuthError extends Error {
  status: number;
  constructor(message: string, status = 401) {
    super(message);
    this.name = "V1AuthError";
    this.status = status;
  }
}
