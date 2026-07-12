/**
 * Invitation codes + one-time invite URLs for controlled onboarding.
 */

import { prisma } from "./db";
import { randomToken, sha256 } from "./crypto";
import { hashPassword, createSession } from "./auth";
import {
  sendInvitationEmail,
  sendInvitationWelcomeEmail,
} from "./mail";

const INVITE_TTL_DAYS = 14;

export type InvitationStatus =
  | "pending"
  | "accepted"
  | "redeemed"
  | "revoked";

function appUrl() {
  return (process.env.NEXT_PUBLIC_APP_URL || "https://promptparle.com").replace(
    /\/$/,
    ""
  );
}

/** Human-readable code: PP-XXXX-XXXX (no ambiguous 0/O/1/I). */
export function generateInviteCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const pick = (n: number) => {
    const bytes = Buffer.from(randomToken(Math.max(n, 8)), "hex");
    let s = "";
    for (let i = 0; i < n; i++) {
      s += alphabet[bytes[i]! % alphabet.length];
    }
    return s;
  };
  return `PP-${pick(4)}-${pick(4)}`;
}

export async function createInvitation(opts: {
  email: string;
  invitedById: string;
  /** The sender's personal message (stored on note; shown in the email + lists). */
  note?: string | null;
}): Promise<{
  invitation: {
    id: string;
    email: string;
    code: string;
    status: string;
    expiresAt: Date;
    createdAt: Date;
  };
  inviteUrl: string;
  rawToken: string;
}> {
  const email = opts.email.toLowerCase().trim();
  if (!email.includes("@")) {
    throw new Error("Valid email required");
  }

  const existingUser = await prisma.user.findUnique({ where: { email } });
  if (existingUser) {
    throw new Error("An account with this email already exists");
  }

  // Block duplicate open invites for same email
  const open = await prisma.invitation.findFirst({
    where: {
      email,
      status: "pending",
      expiresAt: { gt: new Date() },
    },
  });
  if (open) {
    throw new Error(
      "A pending invitation already exists for this email. Revoke it first or wait for expiry."
    );
  }

  let code = generateInviteCode();
  for (let i = 0; i < 5; i++) {
    const clash = await prisma.invitation.findUnique({ where: { code } });
    if (!clash) break;
    code = generateInviteCode();
  }

  const rawToken = randomToken(32);
  const expiresAt = new Date();
  expiresAt.setDate(expiresAt.getDate() + INVITE_TTL_DAYS);

  const message = opts.note?.trim() || null;
  const invitation = await prisma.invitation.create({
    data: {
      email,
      code,
      tokenHash: sha256(rawToken),
      status: "pending",
      invitedById: opts.invitedById,
      note: message,
      expiresAt,
    },
  });

  // Who is inviting (for the email + admin visibility).
  let inviterName: string | null = null;
  try {
    const inviter = await prisma.user.findUnique({
      where: { id: opts.invitedById },
      select: { name: true, email: true },
    });
    inviterName = inviter?.name || inviter?.email || null;
  } catch {
    /* non-fatal */
  }

  // Convenience one-click link (still valid); signup is open, no code shown.
  const inviteUrl = `${appUrl()}/invite/${rawToken}`;

  await sendInvitationEmail({
    to: email,
    inviterName,
    message,
    inviteUrl,
  });

  return {
    invitation: {
      id: invitation.id,
      email: invitation.email,
      code: invitation.code,
      status: invitation.status,
      expiresAt: invitation.expiresAt,
      createdAt: invitation.createdAt,
    },
    inviteUrl,
    rawToken,
  };
}

export async function listInvitations() {
  return prisma.invitation.findMany({
    orderBy: { createdAt: "desc" },
    take: 200,
    include: {
      invitedBy: { select: { email: true, name: true } },
      acceptedUser: { select: { id: true, email: true, name: true } },
    },
  });
}

/**
 * Invitations a specific user has sent (their own only). Used by the user-facing
 * "Invite a friend" area. Admins see everyone's via listInvitations().
 */
export async function listInvitationsByUser(userId: string) {
  return prisma.invitation.findMany({
    where: { invitedById: userId },
    orderBy: { createdAt: "desc" },
    take: 100,
    include: {
      acceptedUser: { select: { id: true, email: true, name: true } },
    },
  });
}

export async function revokeInvitation(id: string) {
  const inv = await prisma.invitation.findUnique({ where: { id } });
  if (!inv) throw new Error("Invitation not found");
  if (inv.status === "redeemed") {
    throw new Error("Cannot revoke a fully redeemed invitation");
  }
  return prisma.invitation.update({
    where: { id },
    data: {
      status: "revoked",
      revokedAt: new Date(),
    },
  });
}

export async function getInvitationByRawToken(rawToken: string) {
  if (!rawToken || rawToken.length < 16) return null;
  return prisma.invitation.findUnique({
    where: { tokenHash: sha256(rawToken) },
  });
}

export async function getInvitationByCode(codeRaw: string) {
  const code = codeRaw.trim().toUpperCase();
  if (!code.startsWith("PP-")) return null;
  return prisma.invitation.findUnique({ where: { code } });
}

/** Public lookup for registration: code must be pending and not expired. */
export async function lookupPendingInviteByCode(codeRaw: string): Promise<
  | { ok: true; email: string; emailMasked: string; expiresAt: Date; code: string }
  | { ok: false; error: string; status: number }
> {
  const inv = await getInvitationByCode(codeRaw);
  if (!inv) {
    return { ok: false, error: "Unknown invitation code", status: 404 };
  }
  if (inv.status === "revoked") {
    return { ok: false, error: "This invitation was revoked", status: 410 };
  }
  if (inv.status === "accepted" || inv.status === "redeemed") {
    return {
      ok: false,
      error: "This invitation was already used. Sign in instead.",
      status: 409,
    };
  }
  if (inv.expiresAt < new Date()) {
    return { ok: false, error: "This invitation has expired", status: 410 };
  }
  return {
    ok: true,
    email: inv.email,
    emailMasked: maskEmail(inv.email),
    expiresAt: inv.expiresAt,
    code: inv.code,
  };
}

async function completeInvitationAccept(opts: {
  inv: {
    id: string;
    email: string;
    code: string;
    status: string;
    expiresAt: Date;
  };
  name?: string | null;
  password: string;
}): Promise<
  | { ok: true; sessionToken: string; userId: string; code: string }
  | { ok: false; error: string; status: number }
> {
  const { inv } = opts;
  if (opts.password.length < 8 || opts.password.length > 128) {
    return {
      ok: false,
      error: "Password must be 8-128 characters",
      status: 400,
    };
  }
  if (inv.status === "revoked") {
    return { ok: false, error: "This invitation was revoked", status: 410 };
  }
  if (inv.status === "redeemed" || inv.status === "accepted") {
    return {
      ok: false,
      error: "This invitation was already used. Sign in instead.",
      status: 409,
    };
  }
  if (inv.expiresAt < new Date()) {
    return { ok: false, error: "This invitation has expired", status: 410 };
  }

  const existing = await prisma.user.findUnique({
    where: { email: inv.email },
  });
  if (existing) {
    return {
      ok: false,
      error: "An account already exists for this email. Sign in instead.",
      status: 409,
    };
  }

  const passwordHash = await hashPassword(opts.password);
  const name = opts.name?.trim() || null;

  const user = await prisma.$transaction(async (tx) => {
    const u = await tx.user.create({
      data: {
        email: inv.email,
        name,
        passwordHash,
        plan: "free",
        emailVerifiedAt: new Date(), // invite proves email ownership
      },
    });
    await tx.invitation.update({
      where: { id: inv.id },
      data: {
        status: "accepted",
        acceptedAt: new Date(),
        acceptedUserId: u.id,
      },
    });
    return u;
  });

  await sendInvitationWelcomeEmail({
    to: user.email,
    name: user.name,
  });

  const sessionToken = await createSession(user.id);
  return {
    ok: true,
    sessionToken,
    userId: user.id,
    code: inv.code,
  };
}

export async function acceptInvitation(opts: {
  rawToken: string;
  name?: string | null;
  password: string;
}): Promise<
  | { ok: true; sessionToken: string; userId: string; code: string }
  | { ok: false; error: string; status: number }
> {
  const inv = await getInvitationByRawToken(opts.rawToken);
  if (!inv) {
    return { ok: false, error: "Invalid invitation link", status: 404 };
  }
  return completeInvitationAccept({
    inv,
    name: opts.name,
    password: opts.password,
  });
}

/** Account creation via invitation code (register page step 1 → form). */
export async function acceptInvitationByCode(opts: {
  code: string;
  name?: string | null;
  password: string;
}): Promise<
  | { ok: true; sessionToken: string; userId: string; code: string }
  | { ok: false; error: string; status: number }
> {
  const inv = await getInvitationByCode(opts.code);
  if (!inv) {
    return { ok: false, error: "Unknown invitation code", status: 404 };
  }
  return completeInvitationAccept({
    inv,
    name: opts.name,
    password: opts.password,
  });
}

/** Public installer: validate invitation code. */
export async function validateInviteCode(codeRaw: string): Promise<
  | {
      ok: true;
      status: string;
      emailMasked: string;
      steps: string[];
      portalUrl: string;
    }
  | { ok: false; error: string }
> {
  const code = codeRaw.trim().toUpperCase();
  if (!code.startsWith("PP-")) {
    return { ok: false, error: "Invalid invitation code format" };
  }

  const inv = await prisma.invitation.findUnique({ where: { code } });
  if (!inv) return { ok: false, error: "Unknown invitation code" };
  if (inv.status === "revoked") {
    return { ok: false, error: "This invitation was revoked" };
  }
  if (inv.expiresAt < new Date() && inv.status === "pending") {
    return { ok: false, error: "This invitation has expired" };
  }
  if (inv.status === "pending") {
    return {
      ok: true,
      status: "pending",
      emailMasked: maskEmail(inv.email),
      portalUrl: `${appUrl()}/invite`,
      steps: [
        "Open the invitation link from your email (or ask your admin to resend).",
        "Complete the account form on PromptParle (not a normal sign-up).",
        "You will receive a second email with this code and install steps.",
        "Then re-run this installer and enter the code again.",
      ],
    };
  }
  if (inv.status === "redeemed") {
    return {
      ok: false,
      error:
        "This invitation code was already used to finish an install. Sign in at the portal or ask for a new invite.",
    };
  }

  // accepted. ready for portal config + API key
  return {
    ok: true,
    status: "accepted",
    emailMasked: maskEmail(inv.email),
    portalUrl: appUrl(),
    steps: [
      "Sign in at https://promptparle.com/login with the email that received the invite.",
      "API Keys → create a desktop license key → copy the full pp_live_… value (shown once).",
      "Return here and paste the desktop license key to finish install.",
      "After install, run pp → ⋯ → Providers and save OpenAI/Claude/Gemini/Grok keys on this PC (not in the portal).",
    ],
  };
}

/** Mark invite redeemed after successful desktop key setup. */
export async function redeemInviteCode(opts: {
  code: string;
  userId: string;
}): Promise<{ ok: true } | { ok: false; error: string }> {
  const code = opts.code.trim().toUpperCase();
  const inv = await prisma.invitation.findUnique({ where: { code } });
  if (!inv) return { ok: false, error: "Unknown invitation code" };
  if (inv.status === "revoked") {
    return { ok: false, error: "Invitation revoked" };
  }
  if (inv.status === "redeemed") {
    return { ok: true }; // idempotent
  }
  if (inv.status !== "accepted" || inv.acceptedUserId !== opts.userId) {
    return {
      ok: false,
      error: "Invitation does not match this account",
    };
  }
  await prisma.invitation.update({
    where: { id: inv.id },
    data: { status: "redeemed", redeemedAt: new Date() },
  });
  return { ok: true };
}

export function maskEmail(email: string): string {
  const [user, domain] = email.split("@");
  if (!user || !domain) return "***";
  const u =
    user.length <= 2
      ? user[0] + "*"
      : user[0] + "***" + user[user.length - 1];
  return `${u}@${domain}`;
}
