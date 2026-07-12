/**
 * Record last-seen IP + country on a user (login, API, etc.).
 */

import { prisma } from "./db";
import { lookupGeo } from "./geoip";

export async function recordUserPresence(
  userId: string,
  ip: string | null | undefined,
  headers?: Headers | null
): Promise<void> {
  const clean = (ip || "").trim();
  if (!clean || clean === "unknown") return;

  try {
    const geo = await lookupGeo(clean, headers);
    await prisma.user.update({
      where: { id: userId },
      data: {
        lastIp: clean.slice(0, 64),
        lastCountry: geo.country ? geo.country.slice(0, 80) : undefined,
        lastCountryCode: geo.countryCode
          ? geo.countryCode.slice(0, 8)
          : undefined,
        lastIpAt: new Date(),
      },
    });
  } catch (err) {
    // Presence must never break login / API
    console.error("recordUserPresence failed", err);
  }
}
