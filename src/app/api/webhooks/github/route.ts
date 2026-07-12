/**
 * GitHub webhooks for PromptParle.
 *
 * Primary use: GitHub Sponsors events (created / cancelled / tier changes)
 * so maintainers get an audit trail (and optional admin email) without
 * gating any product features.
 *
 * Configure in GitHub:
 *   Sponsors dashboard → Settings → Webhooks
 *   (or a personal/org webhook that delivers "Sponsorship" events)
 *
 * Payload URL:  {NEXT_PUBLIC_APP_URL}/api/webhooks/github
 * Content type: application/json
 * Secret:       GITHUB_WEBHOOK_SECRET (must match env)
 *
 * Docs: https://docs.github.com/en/webhooks/webhook-events-and-payloads#sponsorship
 */

import { createHmac, timingSafeEqual } from "crypto";
import { NextRequest, NextResponse } from "next/server";
import { resolveAdminRecipients } from "@/lib/admin-recipients";
import { writeAudit } from "@/lib/audit";
import { isMailConfigured, sendMail } from "@/lib/mail";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type SponsorshipPayload = {
  action?: string;
  zen?: string;
  sender?: { login?: string; html_url?: string; id?: number };
  sponsorship?: {
    privacy_level?: string;
    created_at?: string;
    sponsor?: { login?: string; html_url?: string; id?: number };
    sponsorable?: { login?: string };
    tier?: {
      name?: string;
      monthly_price_in_dollars?: number;
      monthly_price_in_cents?: number;
      is_one_time?: boolean;
      is_custom_amount?: boolean;
    };
  };
  changes?: Record<string, unknown>;
};

function verifyGitHubSignature(
  rawBody: string,
  signatureHeader: string | null,
  secret: string
): boolean {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest("hex");
  const provided = signatureHeader.slice("sha256=".length);
  try {
    const a = Buffer.from(expected, "utf8");
    const b = Buffer.from(provided, "utf8");
    if (a.length !== b.length) return false;
    return timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

function dollarsFromSponsorship(
  sponsorship: SponsorshipPayload["sponsorship"]
): string {
  const t = sponsorship?.tier;
  if (!t) return "unknown";
  if (typeof t.monthly_price_in_dollars === "number") {
    return `$${t.monthly_price_in_dollars}`;
  }
  if (typeof t.monthly_price_in_cents === "number") {
    return `$${(t.monthly_price_in_cents / 100).toFixed(2)}`;
  }
  return "unknown";
}

export async function POST(req: NextRequest) {
  const secret = (process.env.GITHUB_WEBHOOK_SECRET || "").trim();
  if (!secret) {
    console.error("github webhook: GITHUB_WEBHOOK_SECRET is not set");
    return NextResponse.json(
      { error: "webhook not configured" },
      { status: 503 }
    );
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-hub-signature-256");
  if (!verifyGitHubSignature(rawBody, signature, secret)) {
    return NextResponse.json({ error: "invalid signature" }, { status: 401 });
  }

  const event = req.headers.get("x-github-event") || "unknown";
  const delivery = req.headers.get("x-github-delivery") || null;

  let payload: SponsorshipPayload = {};
  try {
    payload = JSON.parse(rawBody) as SponsorshipPayload;
  } catch {
    return NextResponse.json({ error: "invalid json" }, { status: 400 });
  }

  // Always ack pings so GitHub marks the webhook healthy.
  if (event === "ping") {
    await writeAudit({
      action: "sponsors.webhook_ping",
      meta: { delivery, zen: payload.zen || null },
    });
    return NextResponse.json({ ok: true, event: "ping" });
  }

  if (event !== "sponsorship") {
    // Accept other events quietly so a broad webhook config does not fail.
    await writeAudit({
      action: "sponsors.webhook_other",
      meta: {
        event,
        delivery,
        action: payload.action || null,
      },
    });
    return NextResponse.json({ ok: true, ignored: event });
  }

  const action = payload.action || "unknown";
  const sponsorLogin =
    payload.sponsorship?.sponsor?.login || payload.sender?.login || null;
  const tierName = payload.sponsorship?.tier?.name || null;
  const amount = dollarsFromSponsorship(payload.sponsorship);
  const oneTime = Boolean(payload.sponsorship?.tier?.is_one_time);
  const privacy = payload.sponsorship?.privacy_level || null;

  await writeAudit({
    action: "sponsors.event",
    meta: {
      delivery,
      action,
      sponsor: sponsorLogin,
      tier: tierName,
      amount,
      oneTime,
      privacy,
    },
  });

  // Optional admin notice (never blocks the 200 to GitHub).
  try {
    if (isMailConfigured()) {
      const recipients = await resolveAdminRecipients();
      if (recipients.length > 0) {
        const subject = `[PromptParle] GitHub Sponsors: ${action}${
          sponsorLogin ? ` @${sponsorLogin}` : ""
        }`;
        const lines = [
          `GitHub Sponsors event: ${action}`,
          sponsorLogin ? `Sponsor: @${sponsorLogin}` : null,
          tierName ? `Tier: ${tierName}` : null,
          `Amount: ${amount}${oneTime ? " (one-time)" : " (monthly)"}`,
          privacy ? `Privacy: ${privacy}` : null,
          delivery ? `Delivery: ${delivery}` : null,
          "",
          "No product features are gated on sponsorship.",
          "Dashboard: https://github.com/sponsors/exiled4disco/dashboard",
        ].filter(Boolean) as string[];
        const text = lines.join("\n");
        const html = `<pre style="font-family:ui-monospace,monospace;white-space:pre-wrap;">${text
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;")}</pre>`;

        for (const to of recipients) {
          await sendMail({ to, subject, text, html });
        }
      }
    }
  } catch (err) {
    console.error("github webhook: admin mail failed", err);
  }

  return NextResponse.json({ ok: true, event, action });
}

/** Health check for ops (does not reveal the secret). */
export async function GET() {
  const configured = Boolean((process.env.GITHUB_WEBHOOK_SECRET || "").trim());
  return NextResponse.json({
    service: "github-webhook",
    configured,
    accepts: ["sponsorship", "ping"],
  });
}
