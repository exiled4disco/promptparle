/**
 * Lightweight IP → country lookup for admin Accounts.
 * Prefer edge headers when present; otherwise free HTTPS geo API with cache.
 */

export type GeoResult = {
  country: string | null;
  countryCode: string | null;
};

const cache = new Map<string, { at: number; geo: GeoResult }>();
const CACHE_MS = 24 * 60 * 60_000;
const PRIVATE =
  /^(?:10\.|127\.|192\.168\.|172\.(?:1[6-9]|2\d|3[0-1])\.|::1|fc|fd|fe80)/i;

function isPrivateIp(ip: string): boolean {
  return PRIVATE.test(ip) || ip === "unknown" || ip === "localhost";
}

/** Country from reverse-proxy / CDN headers when available. */
export function countryFromHeaders(
  headers?: Headers | null
): GeoResult | null {
  if (!headers) return null;
  const code = (
    headers.get("cf-ipcountry") ||
    headers.get("CF-IPCountry") ||
    headers.get("cloudfront-viewer-country") ||
    headers.get("x-vercel-ip-country") ||
    headers.get("x-country-code") ||
    ""
  )
    .trim()
    .toUpperCase();
  if (!code || code === "XX" || code === "T1") return null;
  return { country: code, countryCode: code };
}

async function fetchIpWhoIs(ip: string): Promise<GeoResult | null> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 2500);
  try {
    const res = await fetch(
      `https://ipwho.is/${encodeURIComponent(ip)}?fields=success,country,country_code`,
      { signal: ctrl.signal, headers: { Accept: "application/json" } }
    );
    if (!res.ok) return null;
    const data = (await res.json()) as {
      success?: boolean;
      country?: string;
      country_code?: string;
    };
    if (data.success === false) return null;
    const country = (data.country || "").trim() || null;
    const countryCode = (data.country_code || "").trim().toUpperCase() || null;
    if (!country && !countryCode) return null;
    return { country: country || countryCode, countryCode };
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/**
 * Resolve country for an IP. Never throws.
 */
export async function lookupGeo(
  ip: string | null | undefined,
  headers?: Headers | null
): Promise<GeoResult> {
  const fromHdr = countryFromHeaders(headers);
  if (fromHdr) return fromHdr;

  const clean = (ip || "").trim();
  if (!clean || isPrivateIp(clean)) {
    return {
      country: clean && isPrivateIp(clean) ? "Private network" : null,
      countryCode: clean && isPrivateIp(clean) ? "LAN" : null,
    };
  }

  const hit = cache.get(clean);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.geo;

  const geo = (await fetchIpWhoIs(clean)) || {
    country: null,
    countryCode: null,
  };
  cache.set(clean, { at: Date.now(), geo });
  return geo;
}
