/**
 * Lightweight security audit trail. Never log secrets or full API keys.
 */

import { prisma } from "./db";

export type AuditAction =
  | "auth.login"
  | "auth.login_failed"
  | "auth.logout"
  | "auth.register"
  | "auth.oauth"
  | "auth.lockout"
  | "auth.password_change"
  | "auth.password_reset_request"
  | "auth.password_reset"
  | "auth.invite_request"
  | "contact.submitted"
  | "contact.reply"
  | "sponsors.event"
  | "sponsors.webhook_ping"
  | "sponsors.webhook_other"
  | "admin.user_disable"
  | "admin.user_enable"
  | "admin.user_delete"
  | "apikey.create"
  | "apikey.revoke"
  | "provider.save"
  | "provider.delete"
  | "settings.update"
  | "allowlist.update"
  | "sponsors.event"
  | "sponsors.webhook_ping"
  | "sponsors.webhook_other";

export async function writeAudit(opts: {
  action: AuditAction;
  userId?: string | null;
  ip?: string | null;
  meta?: Record<string, unknown>;
}): Promise<void> {
  try {
    const metaJson =
      opts.meta && Object.keys(opts.meta).length
        ? JSON.stringify(sanitizeMeta(opts.meta)).slice(0, 4000)
        : null;
    await prisma.auditEvent.create({
      data: {
        userId: opts.userId || null,
        action: opts.action,
        ip: opts.ip ? String(opts.ip).slice(0, 64) : null,
        meta: metaJson,
      },
    });
  } catch (err) {
    // Audit must never break the request path
    console.error("audit write failed", err);
  }
}

function sanitizeMeta(meta: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(meta)) {
    const key = k.toLowerCase();
    if (
      key.includes("password") ||
      key.includes("secret") ||
      key.includes("token") ||
      key.includes("apikey") ||
      key.includes("api_key") ||
      key.includes("authorization")
    ) {
      out[k] = "[redacted]";
      continue;
    }
    if (typeof v === "string") {
      out[k] = v.slice(0, 500);
    } else if (typeof v === "number" || typeof v === "boolean" || v == null) {
      out[k] = v;
    } else {
      out[k] = String(v).slice(0, 200);
    }
  }
  return out;
}
