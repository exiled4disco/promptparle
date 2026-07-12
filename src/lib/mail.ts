import nodemailer from "nodemailer";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

export type SendMailInput = {
  to: string;
  subject: string;
  text: string;
  html: string;
  /** Optional Reply-To (e.g. invitation requester). */
  replyTo?: string;
};

function appUrl(): string {
  return (process.env.NEXT_PUBLIC_APP_URL || "http://localhost:3000").replace(
    /\/$/,
    ""
  );
}

function mailFrom(): string {
  return process.env.MAIL_FROM || "PromptParle <noreply@promptparle.com>";
}

function parseFrom(from: string): { name?: string; address: string } {
  const m = from.match(/^\s*(.*?)\s*<([^>]+)>\s*$/);
  if (m) {
    return { name: m[1].replace(/^["']|["']$/g, "") || undefined, address: m[2] };
  }
  return { address: from.trim() };
}

/** True when at least one outbound path is configured. */
export function isMailConfigured(): boolean {
  const transport = (process.env.MAIL_TRANSPORT || "").toLowerCase();
  if (transport === "smtp" && process.env.SMTP_HOST) return true;
  if (transport === "ses" || process.env.USE_SES === "true") return true;
  if (process.env.RESEND_API_KEY) return true;
  if (process.env.SMTP_HOST) return true;
  if (transport === "sendmail") return true;
  if (process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION) return true;
  return false;
}

async function sendViaSes(input: SendMailInput): Promise<void> {
  const region =
    process.env.AWS_REGION ||
    process.env.AWS_DEFAULT_REGION ||
    "us-east-2";
  const client = new SESv2Client({ region });
  const from = parseFrom(mailFrom());

  await client.send(
    new SendEmailCommand({
      FromEmailAddress: from.name
        ? `${from.name} <${from.address}>`
        : from.address,
      Destination: { ToAddresses: [input.to] },
      ReplyToAddresses: input.replyTo ? [input.replyTo] : undefined,
      Content: {
        Simple: {
          Subject: { Data: input.subject, Charset: "UTF-8" },
          Body: {
            Text: { Data: input.text, Charset: "UTF-8" },
            Html: { Data: input.html, Charset: "UTF-8" },
          },
        },
      },
    })
  );
}

async function sendViaResend(input: SendMailInput): Promise<void> {
  const key = process.env.RESEND_API_KEY;
  if (!key) throw new Error("RESEND_API_KEY not set");

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: mailFrom(),
      to: [input.to],
      subject: input.subject,
      html: input.html,
      text: input.text,
      ...(input.replyTo ? { reply_to: input.replyTo } : {}),
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Resend failed (${res.status}): ${body}`);
  }
}

async function sendViaSmtp(input: SendMailInput): Promise<void> {
  const host = process.env.SMTP_HOST;
  if (!host) throw new Error("SMTP_HOST not set");

  const port = Number(process.env.SMTP_PORT || "587");
  const secure =
    process.env.SMTP_SECURE === "true" ||
    process.env.SMTP_SECURE === "1" ||
    port === 465;

  const transporter = nodemailer.createTransport({
    host,
    port,
    secure,
    auth:
      process.env.SMTP_USER && process.env.SMTP_PASS
        ? {
            user: process.env.SMTP_USER,
            pass: process.env.SMTP_PASS,
          }
        : undefined,
  });

  await transporter.sendMail({
    from: mailFrom(),
    to: input.to,
    replyTo: input.replyTo,
    subject: input.subject,
    text: input.text,
    html: input.html,
  });
}

async function sendViaSendmail(input: SendMailInput): Promise<void> {
  const transporter = nodemailer.createTransport({
    sendmail: true,
    newline: "unix",
    path: process.env.SENDMAIL_PATH || "/usr/sbin/sendmail",
  });

  await transporter.sendMail({
    from: mailFrom(),
    to: input.to,
    replyTo: input.replyTo,
    subject: input.subject,
    text: input.text,
    html: input.html,
  });
}

/**
 * Send transactional email.
 * Priority:
 * 1. MAIL_TRANSPORT=ses / USE_SES=true
 * 2. RESEND_API_KEY
 * 3. SMTP_HOST
 * 4. MAIL_TRANSPORT=sendmail
 * 5. Default SES when AWS region is available
 */
export async function sendMail(input: SendMailInput): Promise<void> {
  const transport = (process.env.MAIL_TRANSPORT || "").toLowerCase();

  // Explicit transport wins
  if (transport === "smtp") {
    await sendViaSmtp(input);
    return;
  }
  if (transport === "ses" || process.env.USE_SES === "true") {
    await sendViaSes(input);
    return;
  }
  if (transport === "resend" || process.env.RESEND_API_KEY) {
    if (process.env.RESEND_API_KEY) {
      await sendViaResend(input);
      return;
    }
  }
  if (transport === "sendmail") {
    await sendViaSendmail(input);
    return;
  }

  // Auto-detect when MAIL_TRANSPORT unset
  if (process.env.SMTP_HOST) {
    await sendViaSmtp(input);
    return;
  }
  if (process.env.RESEND_API_KEY) {
    await sendViaResend(input);
    return;
  }
  if (process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION) {
    await sendViaSes(input);
    return;
  }
  throw new Error(
    "Email is not configured. Set SMTP_HOST, RESEND_API_KEY, or MAIL_TRANSPORT=ses."
  );
}

export async function sendVerificationEmail(
  to: string,
  rawToken: string,
  name?: string | null
): Promise<void> {
  const verifyUrl = `${appUrl()}/verify-email?token=${encodeURIComponent(rawToken)}`;
  const greeting = name ? `Hi ${name},` : "Hi,";

  const text = `${greeting}

Confirm your PromptParle account by opening this link:

${verifyUrl}

This link expires in 24 hours. If you did not create an account, you can ignore this email.

PromptParle
Trim the prompt. Keep the signal.
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:520px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:8px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="color:#8b9bb8;margin:0 0 20px;">Trim the prompt. Keep the signal.</p>
    <p style="margin:0 0 12px;">${greeting}</p>
    <p style="margin:0 0 20px;color:#c7d7f5;">Confirm your email to activate your account.</p>
    <p style="margin:0 0 28px;">
      <a href="${verifyUrl}"
         style="display:inline-block;background:linear-gradient(135deg,#5b8cff,#3d6ef5);color:#fff;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:999px;">
        Verify email
      </a>
    </p>
    <p style="font-size:13px;color:#5c6b86;margin:0 0 8px;">Or paste this link into your browser:</p>
    <p style="font-size:12px;word-break:break-all;color:#8b9bb8;margin:0 0 20px;">${verifyUrl}</p>
    <p style="font-size:12px;color:#5c6b86;margin:0;">This link expires in 24 hours. If you did not sign up, ignore this message.</p>
  </div>
</body>
</html>`;

  if (process.env.MAIL_DEBUG === "true") {
    console.info(`[mail-debug] verification link for ${to}: ${verifyUrl}`);
  }

  await sendMail({
    to,
    subject: "Verify your PromptParle account",
    text,
    html,
  });
}

export async function sendInvitationEmail(opts: {
  to: string;
  inviteUrl: string;
  expiresAt: Date;
  codePreview: string;
}): Promise<void> {
  const { to, inviteUrl, expiresAt, codePreview } = opts;
  const exp = expiresAt.toUTCString();

  const registerUrl = `${appUrl()}/register`;

  const text = `You're invited to PromptParle (it's free)

A friend invited you to PromptParle, the AI context optimization gateway. PromptParle is free for everyone, this invite just gives you a warm one-click start.

YOUR INVITE CODE (optional, pre-fills your signup)
${codePreview}

Option A (one click):
${inviteUrl}

Option B (on the website):
1) Go to ${registerUrl}
2) The invite code above pre-fills, or just sign up directly (it's open)
3) Set your name and password

This invite link expires ${exp}.
After you create your account, we'll email desktop install steps.

PromptParle
Trim the prompt. Keep the signal.
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:560px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:8px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="color:#8b9bb8;margin:0 0 20px;">You're invited (it's free)</p>
    <p style="margin:0 0 12px;color:#c7d7f5;">A friend invited you to PromptParle. It's free for everyone, this is just a warm one-click start.</p>
    <p style="margin:0 0 10px;color:#8b9bb8;font-size:14px;">Your invite code (optional, pre-fills your signup):</p>
    <div style="background:#0d111a;border:1px solid #2a3a55;border-radius:10px;padding:14px 16px;margin:0 0 22px;text-align:center;">
      <code style="font-size:20px;letter-spacing:0.12em;font-weight:700;color:#93b4ff;">${codePreview}</code>
    </div>
    <p style="margin:0 0 28px;">
      <a href="${inviteUrl}"
         style="display:inline-block;background:linear-gradient(135deg,#5b8cff,#3d6ef5);color:#fff;text-decoration:none;font-weight:600;padding:12px 22px;border-radius:999px;">
        Accept invitation
      </a>
    </p>
    <p style="font-size:13px;color:#8b9bb8;margin:0 0 8px;">Or go to <a href="${registerUrl}" style="color:#93b4ff;">${registerUrl}</a> and sign up directly, the code above pre-fills if you use the link.</p>
    <p style="font-size:12px;color:#5c6b86;margin:0;">Invite link expires ${exp}. After signup you get desktop install steps by email.</p>
  </div>
</body>
</html>`;

  if (process.env.MAIL_DEBUG === "true") {
    console.info(`[mail-debug] invitation for ${to}: ${inviteUrl}`);
  }

  await sendMail({
    to,
    subject: "You're invited to PromptParle",
    text,
    html,
  });
}

export async function sendInvitationWelcomeEmail(opts: {
  to: string;
  name?: string | null;
  code: string;
}): Promise<void> {
  const greeting = opts.name ? `Hi ${opts.name},` : "Hi,";
  const portal = appUrl();
  const installCmdWin = `irm ${portal}/install.ps1 | iex`;
  const installCmdLinux = `curl -fsSL ${portal}/install.sh | bash`;

  const text = `${greeting}

Your PromptParle account is ready. Here is your one-time invitation code and install guide.

════════════════════════════════════
  INVITATION CODE (enter during install)
  ${opts.code}
════════════════════════════════════

INSTALL (Windows PowerShell)

1) Open PowerShell
2) Run:
   ${installCmdWin}
3) When asked, enter invitation code: ${opts.code}
4) Finish portal setup (below), then paste your desktop API key.

INSTALL (Linux / macOS)

1) Install PowerShell 7+ (pwsh) if needed
2) Run:
   ${installCmdLinux}
3) When asked, enter invitation code: ${opts.code}
4) Finish portal setup (below), then paste your desktop API key.

PORTAL SETUP (required once)

1) Sign in: ${portal}/login
   Email: ${opts.to}
2) Providers → add your AI provider key (OpenAI / Claude / Gemini / Grok)
   Keys stay encrypted; spend is on YOUR provider account (BYOK).
3) API Keys → Create desktop key → copy the full pp_live_… value (shown once)
4) Return to the installer and paste that key.

SECURITY NOTES
• Invitation codes are single-use for onboarding
• Desktop UI runs only on your PC (127.0.0.1)
• SSH/git credentials never leave your machine

Need help? Reply to this email or visit ${portal}

PromptParle
Trim the prompt. Keep the signal.
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:560px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:8px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="color:#8b9bb8;margin:0 0 16px;">Account ready: install next</p>
    <p style="margin:0 0 16px;">${greeting}</p>
    <p style="margin:0 0 12px;color:#c7d7f5;">Your one-time invitation code (enter this in the desktop installer):</p>
    <div style="background:#0d111a;border:1px solid #2a3a55;border-radius:10px;padding:16px 18px;margin:0 0 24px;text-align:center;">
      <code style="font-size:22px;letter-spacing:0.12em;font-weight:700;color:#93b4ff;">${opts.code}</code>
    </div>

    <h3 style="margin:0 0 10px;font-size:14px;color:#e8eef8;">1 · Install (Windows)</h3>
    <ol style="margin:0 0 16px;padding-left:20px;color:#8b9bb8;font-size:14px;line-height:1.55;">
      <li>Open PowerShell</li>
      <li>Run: <code style="color:#93b4ff;background:#0d111a;padding:2px 6px;border-radius:4px;">${installCmdWin}</code></li>
      <li>Enter invitation code <strong style="color:#e8eef8;">${opts.code}</strong> when prompted</li>
    </ol>

    <h3 style="margin:0 0 10px;font-size:14px;color:#e8eef8;">1b · Install (Linux / macOS)</h3>
    <ol style="margin:0 0 20px;padding-left:20px;color:#8b9bb8;font-size:14px;line-height:1.55;">
      <li>Install PowerShell 7+ (<code style="color:#93b4ff;">pwsh</code>) if needed</li>
      <li>Run: <code style="color:#93b4ff;background:#0d111a;padding:2px 6px;border-radius:4px;">${installCmdLinux}</code></li>
      <li>Enter invitation code <strong style="color:#e8eef8;">${opts.code}</strong> when prompted</li>
    </ol>

    <h3 style="margin:0 0 10px;font-size:14px;color:#e8eef8;">2 · Portal setup</h3>
    <ol style="margin:0 0 20px;padding-left:20px;color:#8b9bb8;font-size:14px;line-height:1.55;">
      <li>Sign in at <a href="${portal}/login" style="color:#93b4ff;">${portal}/login</a> (${opts.to})</li>
      <li><strong style="color:#e8eef8;">Providers</strong> → add your AI API key (BYOK: your provider bill)</li>
      <li><strong style="color:#e8eef8;">API Keys</strong> → create desktop key → copy <code style="color:#93b4ff;">pp_live_…</code> (shown once)</li>
      <li>Return to the installer and paste the desktop key</li>
    </ol>

    <p style="font-size:12px;color:#5c6b86;margin:0;">Code is single-use for onboarding. Local UI stays on your PC. SSH/git credentials never leave your machine.</p>
  </div>
</body>
</html>`;

  await sendMail({
    to: opts.to,
    subject: `PromptParle install guide (code ${opts.code})`,
    text,
    html,
  });
}

export async function sendPasswordResetEmail(
  to: string,
  rawToken: string,
  name?: string | null
): Promise<void> {
  const resetUrl = `${appUrl()}/reset-password?token=${encodeURIComponent(rawToken)}`;
  const greeting = name ? `Hi ${name},` : "Hi,";

  const text = `${greeting}

We received a request to reset your PromptParle password.

Open this link to choose a new password (expires in 1 hour):

${resetUrl}

If you did not request this, you can ignore this email. Your password will stay the same.

PromptParle
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:520px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:8px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="color:#8b9bb8;margin:0 0 20px;">Password reset</p>
    <p style="margin:0 0 12px;">${greeting}</p>
    <p style="margin:0 0 20px;color:#c7d7f5;">Choose a new password for your account.</p>
    <p style="margin:0 0 28px;">
      <a href="${resetUrl}"
         style="display:inline-block;background:linear-gradient(135deg,#5b8cff,#3d6ef5);color:#fff;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:999px;">
        Reset password
      </a>
    </p>
    <p style="font-size:13px;color:#5c6b86;margin:0 0 8px;">Or paste this link into your browser:</p>
    <p style="font-size:12px;word-break:break-all;color:#8b9bb8;margin:0 0 20px;">${resetUrl}</p>
    <p style="font-size:12px;color:#5c6b86;margin:0;">This link expires in 1 hour. If you did not request a reset, ignore this message.</p>
  </div>
</body>
</html>`;

  if (process.env.MAIL_DEBUG === "true") {
    console.info(`[mail-debug] password reset link for ${to}: ${resetUrl}`);
  }

  await sendMail({
    to,
    subject: "Reset your PromptParle password",
    text,
    html,
  });
}

/** Notify admins that someone requested an invitation. */
export async function sendInviteRequestEmail(opts: {
  to: string | string[];
  name: string;
  email: string;
  company?: string | null;
  note?: string | null;
  ip?: string | null;
}): Promise<void> {
  const recipients = Array.isArray(opts.to) ? opts.to : [opts.to];
  const adminUrl = `${appUrl()}/app/invitations`;
  const company = (opts.company || "").trim() || "(not provided)";
  const note = (opts.note || "").trim() || "(none)";
  const ip = opts.ip || "unknown";

  const text = `New PromptParle invitation request

Name: ${opts.name}
Email: ${opts.email}
Company: ${company}
Note: ${note}
IP: ${ip}

Open the invitation manager to send a code:
${adminUrl}

PromptParle
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:560px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:8px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="color:#8b9bb8;margin:0 0 16px;">New invitation request</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px;color:#c7d7f5;margin:0 0 22px;">
      <tr><td style="padding:6px 0;color:#8b9bb8;width:110px;">Name</td><td style="padding:6px 0;">${escapeHtml(opts.name)}</td></tr>
      <tr><td style="padding:6px 0;color:#8b9bb8;">Email</td><td style="padding:6px 0;"><a href="mailto:${escapeHtml(opts.email)}" style="color:#93b4ff;">${escapeHtml(opts.email)}</a></td></tr>
      <tr><td style="padding:6px 0;color:#8b9bb8;">Company</td><td style="padding:6px 0;">${escapeHtml(company)}</td></tr>
      <tr><td style="padding:6px 0;color:#8b9bb8;vertical-align:top;">Note</td><td style="padding:6px 0;white-space:pre-wrap;">${escapeHtml(note)}</td></tr>
      <tr><td style="padding:6px 0;color:#8b9bb8;">IP</td><td style="padding:6px 0;">${escapeHtml(ip)}</td></tr>
    </table>
    <p style="margin:0;">
      <a href="${adminUrl}"
         style="display:inline-block;background:linear-gradient(135deg,#5b8cff,#3d6ef5);color:#fff;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:999px;">
        Open invitation manager
      </a>
    </p>
  </div>
</body>
</html>`;

  for (const to of recipients) {
    await sendMail({
      to,
      // Reply goes to the person who requested access
      replyTo: opts.email,
      subject: `Invite request: ${opts.email}`,
      text,
      html,
    });
  }
}

/** Notify admins of a bug report or product suggestion. */
export async function sendFeedbackNotifyEmail(opts: {
  to: string | string[];
  kind: string;
  title: string;
  body: string;
  source: string;
  email?: string | null;
  name?: string | null;
  userId?: string | null;
  ip?: string | null;
  country?: string | null;
}): Promise<void> {
  const recipients = Array.isArray(opts.to) ? opts.to : [opts.to];
  const adminUrl = `${appUrl()}/app/feedback`;
  const kindLabel =
    opts.kind === "bug"
      ? "Bug report"
      : opts.kind === "contact"
        ? "Contact message"
        : "Suggestion";
  const who =
    [opts.name, opts.email].filter(Boolean).join(" · ") ||
    opts.userId ||
    "anonymous";
  const loc = [opts.ip, opts.country].filter(Boolean).join(" · ") || "unknown";

  const text = `New PromptParle ${kindLabel}

From: ${who}
Source: ${opts.source}
Title: ${opts.title}

${opts.body}

Location: ${loc}

Open feedback inbox:
${adminUrl}
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:560px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:8px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="color:#8b9bb8;margin:0 0 12px;">${escapeHtml(kindLabel)}</p>
    <p style="margin:0 0 8px;font-size:16px;font-weight:600;">${escapeHtml(opts.title)}</p>
    <p style="margin:0 0 16px;color:#c7d7f5;white-space:pre-wrap;font-size:14px;">${escapeHtml(opts.body)}</p>
    <table style="width:100%;border-collapse:collapse;font-size:13px;color:#8b9bb8;margin:0 0 22px;">
      <tr><td style="padding:4px 0;width:90px;">From</td><td style="padding:4px 0;color:#c7d7f5;">${escapeHtml(who)}</td></tr>
      <tr><td style="padding:4px 0;">Source</td><td style="padding:4px 0;color:#c7d7f5;">${escapeHtml(opts.source)}</td></tr>
      <tr><td style="padding:4px 0;">Location</td><td style="padding:4px 0;color:#c7d7f5;">${escapeHtml(loc)}</td></tr>
    </table>
    <p style="margin:0;">
      <a href="${adminUrl}"
         style="display:inline-block;background:linear-gradient(135deg,#5b8cff,#3d6ef5);color:#fff;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:999px;">
        Open feedback inbox
      </a>
    </p>
  </div>
</body>
</html>`;

  for (const to of recipients) {
    await sendMail({
      to,
      replyTo: opts.email || undefined,
      subject: `${kindLabel}: ${opts.title}`.slice(0, 180),
      text,
      html,
    });
  }
}

/**
 * Admin reply to a contact/feedback message — sent TO the original submitter.
 * Quotes their original message so the thread makes sense on their end.
 */
export async function sendContactReplyEmail(opts: {
  to: string;
  name?: string | null;
  originalSubject: string;
  originalBody: string;
  reply: string;
  adminName?: string | null;
}): Promise<void> {
  const greeting = opts.name ? `Hi ${opts.name},` : "Hi,";
  const signoff = opts.adminName
    ? `— ${opts.adminName}, PromptParle`
    : "— PromptParle";

  const text = `${greeting}

${opts.reply}

${signoff}

---
Your original message:
Subject: ${opts.originalSubject}

${opts.originalBody}
`;

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;background:#07090f;color:#e8eef8;padding:32px;">
  <div style="max-width:560px;margin:0 auto;background:#111827;border:1px solid #1e2a3d;border-radius:12px;padding:28px;">
    <div style="font-size:18px;font-weight:700;margin-bottom:12px;">Prompt<span style="color:#93b4ff;">Parle</span></div>
    <p style="margin:0 0 12px;color:#c7d7f5;">${escapeHtml(greeting)}</p>
    <p style="margin:0 0 18px;color:#e8eef8;white-space:pre-wrap;font-size:14px;line-height:1.5;">${escapeHtml(opts.reply)}</p>
    <p style="margin:0 0 22px;color:#8b9bb8;font-size:13px;">${escapeHtml(signoff)}</p>
    <div style="border-top:1px solid #1e2a3d;padding-top:14px;color:#6b7a92;font-size:12px;">
      <div style="margin-bottom:6px;">Your original message:</div>
      <div style="color:#8b9bb8;margin-bottom:4px;">${escapeHtml(opts.originalSubject)}</div>
      <div style="white-space:pre-wrap;color:#8b9bb8;">${escapeHtml(opts.originalBody)}</div>
    </div>
  </div>
</body>
</html>`;

  await sendMail({
    to: opts.to,
    subject: `Re: ${opts.originalSubject}`.slice(0, 180),
    text,
    html,
  });
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
