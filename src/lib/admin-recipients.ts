import { prisma } from "./db";

/** Admin emails for operational notices (invite requests, feedback, etc.). */
export async function resolveAdminRecipients(): Promise<string[]> {
  const fromEnv = [
    ...(process.env.INVITE_REQUEST_TO || "").split(","),
    ...(process.env.ADMIN_EMAIL || "").split(","),
    ...(process.env.FEEDBACK_TO || "").split(","),
  ]
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.includes("@"));

  const admins = await prisma.user.findMany({
    where: { isAdmin: true },
    select: { email: true },
    take: 50,
  });
  const fromAdmins = admins
    .map((a) => (a.email || "").trim().toLowerCase())
    .filter((s) => s.includes("@"));

  return [...new Set([...fromEnv, ...fromAdmins])];
}
