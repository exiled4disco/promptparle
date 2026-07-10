import nodemailer from "nodemailer";
import { SESv2Client, SendEmailCommand } from "@aws-sdk/client-sesv2";

export type SendMailInput = {
  to: string;
  subject: string;
  text: string;
  html: string;
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

— PromptParle
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
