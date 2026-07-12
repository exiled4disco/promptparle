import { cookies } from "next/headers";
import bcrypt from "bcryptjs";
import { prisma } from "./db";
import { randomToken, sha256 } from "./crypto";
import { SESSION_COOKIE, SESSION_DAYS } from "./constants";
import { recordUserPresence } from "./user-presence";

export type SessionUser = {
  id: string;
  email: string;
  name: string | null;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  emailVerifiedAt: Date | null;
  onboardedAt: Date | null;
  featProjectPc: boolean;
  featProjectSsh: boolean;
  featProjectGit: boolean;
  /** API key allowlist (IPv4/CIDR text). Empty/null = unrestricted. */
  allowedIps: string | null;
  preferredProvider: string | null;
  preferredModels: string | null;
  defaultDial: number;
  defaultToolsEnabled: boolean;
  /** True if account has a password (false = OAuth-only until they set one). */
  hasPassword: boolean;
  /** Portal administrator (invitation manager). */
  isAdmin: boolean;
  /** When set, account is disabled by an admin. */
  disabledAt: Date | null;
};

export async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, 12);
}

export async function verifyPassword(
  password: string,
  hash: string | null | undefined
): Promise<boolean> {
  if (!hash) return false;
  return bcrypt.compare(password, hash);
}

export async function createSession(
  userId: string,
  meta?: { userAgent?: string; ipAddress?: string; headers?: Headers }
): Promise<string> {
  const token = randomToken(32);
  const tokenHash = sha256(token);
  const expiresAt = new Date();
  expiresAt.setDate(expiresAt.getDate() + SESSION_DAYS);

  await prisma.session.create({
    data: {
      userId,
      tokenHash,
      expiresAt,
      userAgent: meta?.userAgent,
      ipAddress: meta?.ipAddress,
    },
  });

  if (meta?.ipAddress) {
    void recordUserPresence(userId, meta.ipAddress, meta.headers);
  }

  return token;
}

export async function setSessionCookie(token: string): Promise<void> {
  const cookieStore = await cookies();
  cookieStore.set(SESSION_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: SESSION_DAYS * 24 * 60 * 60,
  });
}

export async function clearSessionCookie(): Promise<void> {
  const cookieStore = await cookies();
  cookieStore.delete(SESSION_COOKIE);
}

export async function destroySession(token: string): Promise<void> {
  await prisma.session.deleteMany({
    where: { tokenHash: sha256(token) },
  });
}

export async function getSessionUser(): Promise<SessionUser | null> {
  const cookieStore = await cookies();
  const token = cookieStore.get(SESSION_COOKIE)?.value;
  if (!token) return null;

  const session = await prisma.session.findUnique({
    where: { tokenHash: sha256(token) },
    include: {
      user: {
        select: {
          id: true,
          email: true,
          name: true,
          plan: true,
          retentionPolicy: true,
          storePrompts: true,
          emailVerifiedAt: true,
          onboardedAt: true,
          featProjectPc: true,
          featProjectSsh: true,
          featProjectGit: true,
          allowedIps: true,
          preferredProvider: true,
          preferredModels: true,
          defaultDial: true,
          defaultToolsEnabled: true,
          passwordHash: true,
          isAdmin: true,
          disabledAt: true,
        },
      },
    },
  });

  if (!session) return null;

  if (session.expiresAt < new Date()) {
    await prisma.session.delete({ where: { id: session.id } }).catch(() => {});
    return null;
  }

  // Admin-disabled accounts lose the session immediately
  if (session.user.disabledAt) {
    await prisma.session
      .delete({ where: { id: session.id } })
      .catch(() => {});
    return null;
  }

  const u = session.user;
  const { passwordHash, ...rest } = u;
  return {
    ...rest,
    hasPassword: Boolean(passwordHash),
    isAdmin: Boolean(u.isAdmin),
    disabledAt: u.disabledAt ?? null,
    defaultDial: u.defaultDial ?? 3,
    defaultToolsEnabled: u.defaultToolsEnabled !== false,
    featProjectPc: u.featProjectPc !== false,
    featProjectSsh: u.featProjectSsh !== false,
    featProjectGit: u.featProjectGit !== false,
  };
}

/** Wipe all browser sessions for a user (disable / password reset). */
export async function destroyAllSessionsForUser(userId: string): Promise<void> {
  await prisma.session.deleteMany({ where: { userId } });
}

export async function requireUser(): Promise<SessionUser> {
  const user = await getSessionUser();
  if (!user) {
    throw new AuthError("Unauthorized");
  }
  if (!user.emailVerifiedAt) {
    throw new AuthError("Email not verified", 403);
  }
  return user;
}

export async function requireAdmin(): Promise<SessionUser> {
  const user = await requireUser();
  if (!user.isAdmin) {
    throw new AuthError("Administrator access required", 403);
  }
  return user;
}

export class AuthError extends Error {
  status: number;
  constructor(message = "Unauthorized", status = 401) {
    super(message);
    this.name = "AuthError";
    this.status = status;
  }
}
