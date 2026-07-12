import { NextResponse } from "next/server";
import { AuthError, requireAdmin } from "@/lib/auth";
import { prisma } from "@/lib/db";

/**
 * Admin: list registered portal accounts.
 * Active = verified and not disabled.
 */
export async function GET() {
  try {
    await requireAdmin();

    const rows = await prisma.user.findMany({
      orderBy: { createdAt: "desc" },
      select: {
        id: true,
        email: true,
        name: true,
        plan: true,
        isAdmin: true,
        emailVerifiedAt: true,
        createdAt: true,
        updatedAt: true,
        preferredProvider: true,
        lastIp: true,
        lastCountry: true,
        lastCountryCode: true,
        lastIpAt: true,
        disabledAt: true,
        disabledReason: true,
        _count: {
          select: {
            apiKeys: true,
            providerCredentials: true,
            sessions: true,
            desktopClients: true,
            promptRequests: true,
          },
        },
        sessions: {
          orderBy: { createdAt: "desc" },
          take: 1,
          select: { createdAt: true, ipAddress: true },
        },
        desktopClients: {
          orderBy: { lastSeenAt: "desc" },
          take: 1,
          select: { lastSeenAt: true, hostname: true, platform: true },
        },
      },
    });

    const users = rows.map((u) => {
      const lastSessionAt = u.sessions[0]?.createdAt ?? null;
      const lastDesktopAt = u.desktopClients[0]?.lastSeenAt ?? null;
      let lastActiveAt: Date | null = null;
      if (lastSessionAt && lastDesktopAt) {
        lastActiveAt =
          lastSessionAt > lastDesktopAt ? lastSessionAt : lastDesktopAt;
      } else {
        lastActiveAt = lastSessionAt || lastDesktopAt;
      }

      const verified = Boolean(u.emailVerifiedAt);
      const disabled = Boolean(u.disabledAt);
      const ip = u.lastIp || u.sessions[0]?.ipAddress || null;

      return {
        id: u.id,
        email: u.email,
        name: u.name,
        plan: u.plan,
        isAdmin: u.isAdmin,
        verified,
        disabled,
        disabledAt: u.disabledAt,
        disabledReason: u.disabledReason,
        emailVerifiedAt: u.emailVerifiedAt,
        createdAt: u.createdAt,
        updatedAt: u.updatedAt,
        preferredProvider: u.preferredProvider,
        lastActiveAt,
        lastIp: ip,
        lastCountry: u.lastCountry,
        lastCountryCode: u.lastCountryCode,
        lastIpAt: u.lastIpAt,
        lastDesktop: u.desktopClients[0]
          ? {
              hostname: u.desktopClients[0].hostname,
              platform: u.desktopClients[0].platform,
              lastSeenAt: u.desktopClients[0].lastSeenAt,
            }
          : null,
        counts: {
          apiKeys: u._count.apiKeys,
          providers: u._count.providerCredentials,
          sessions: u._count.sessions,
          desktopClients: u._count.desktopClients,
          promptRequests: u._count.promptRequests,
        },
      };
    });

    return NextResponse.json({
      users,
      summary: {
        total: users.length,
        active: users.filter((u) => u.verified && !u.disabled).length,
        disabled: users.filter((u) => u.disabled).length,
        admins: users.filter((u) => u.isAdmin).length,
      },
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin users GET", err);
    return NextResponse.json(
      { error: "Failed to list accounts" },
      { status: 500 }
    );
  }
}
