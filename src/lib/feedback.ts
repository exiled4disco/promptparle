import { prisma } from "./db";
import { isMailConfigured, sendFeedbackNotifyEmail } from "./mail";
import { resolveAdminRecipients } from "./admin-recipients";
import { lookupGeo } from "./geoip";

export type FeedbackKind = "bug" | "suggest";
export type FeedbackSource = "portal" | "desktop";

export async function createFeedback(opts: {
  kind: FeedbackKind;
  title: string;
  body: string;
  source: FeedbackSource;
  userId?: string | null;
  email?: string | null;
  name?: string | null;
  ip?: string | null;
  userAgent?: string | null;
  headers?: Headers | null;
}) {
  const title = opts.title.trim().slice(0, 200);
  const body = opts.body.trim().slice(0, 8000);
  if (!title || !body) {
    throw new Error("Title and details are required");
  }
  const kind: FeedbackKind = opts.kind === "bug" ? "bug" : "suggest";
  const source: FeedbackSource =
    opts.source === "desktop" ? "desktop" : "portal";

  let country: string | null = null;
  if (opts.ip) {
    const geo = await lookupGeo(opts.ip, opts.headers);
    country = geo.country || geo.countryCode || null;
  }

  const row = await prisma.feedbackSubmission.create({
    data: {
      kind,
      title,
      body,
      source,
      userId: opts.userId || null,
      email: opts.email ? opts.email.toLowerCase().slice(0, 255) : null,
      name: opts.name ? opts.name.slice(0, 120) : null,
      ip: opts.ip ? opts.ip.slice(0, 64) : null,
      country: country ? country.slice(0, 80) : null,
      userAgent: opts.userAgent ? opts.userAgent.slice(0, 400) : null,
      status: "new",
    },
  });

  if (isMailConfigured()) {
    try {
      const recipients = await resolveAdminRecipients();
      if (recipients.length) {
        await sendFeedbackNotifyEmail({
          to: recipients,
          kind,
          title,
          body,
          source,
          email: opts.email,
          name: opts.name,
          userId: opts.userId,
          ip: opts.ip,
          country,
        });
      }
    } catch (err) {
      console.error("feedback notify email failed", err);
    }
  }

  return row;
}

/**
 * User-scoped list: ONLY the signed-in user's own submissions.
 * Never returns rows belonging to other users (privacy contract).
 */
export async function listUserFeedback(
  userId: string,
  opts?: { take?: number }
) {
  return prisma.feedbackSubmission.findMany({
    where: { userId },
    orderBy: { createdAt: "desc" },
    take: Math.min(opts?.take ?? 100, 200),
    select: {
      id: true,
      kind: true,
      title: true,
      body: true,
      status: true,
      adminNote: true,
      createdAt: true,
    },
  });
}

export async function listFeedback(opts?: {
  status?: string | null;
  take?: number;
}) {
  const where =
    opts?.status && opts.status !== "all"
      ? { status: opts.status }
      : undefined;
  return prisma.feedbackSubmission.findMany({
    where,
    orderBy: { createdAt: "desc" },
    take: Math.min(opts?.take ?? 100, 200),
    include: {
      user: { select: { id: true, email: true, name: true } },
    },
  });
}
