/**
 * API IP/CIDR allowlist helpers.
 *
 * Empty list = unrestricted. Used for desktop API keys (v1/*) only
 * browser session/Settings stay open so users can fix a bad list.
 */

export type IpParseResult =
  | { ok: true; entries: string[]; normalized: string | null }
  | { ok: false; error: string };

const IPV4_RE =
  /^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$/;
const CIDR_RE =
  /^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\/(?:[0-9]|[1-2]\d|3[0-2])$/;

/** Split user input into candidate entries (newline / comma / semicolon). */
export function splitIpList(raw: string | null | undefined): string[] {
  if (!raw) return [];
  return raw
    .split(/[\n,;]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

/** Validate + normalize a free-text allowlist. Max 32 entries. */
export function parseAllowedIpsInput(
  raw: string | null | undefined
): IpParseResult {
  if (raw == null) {
    return { ok: true, entries: [], normalized: null };
  }
  const trimmed = String(raw).trim();
  if (!trimmed) {
    return { ok: true, entries: [], normalized: null };
  }

  const parts = splitIpList(trimmed);
  if (parts.length > 32) {
    return { ok: false, error: "At most 32 IP/CIDR entries allowed" };
  }

  const entries: string[] = [];
  for (const p of parts) {
    if (CIDR_RE.test(p)) {
      entries.push(p);
      continue;
    }
    if (IPV4_RE.test(p)) {
      entries.push(p);
      continue;
    }
    return {
      ok: false,
      error: `Invalid IP or CIDR: ${p} (use e.g. 203.0.113.10 or 10.0.0.0/8)`,
    };
  }

  // de-dupe preserving order
  const seen = new Set<string>();
  const unique = entries.filter((e) => {
    if (seen.has(e)) return false;
    seen.add(e);
    return true;
  });

  return {
    ok: true,
    entries: unique,
    normalized: unique.length ? unique.join("\n") : null,
  };
}

function ipv4ToInt(ip: string): number | null {
  if (!IPV4_RE.test(ip)) return null;
  const parts = ip.split(".").map((x) => Number(x));
  return (
    ((parts[0]! << 24) >>> 0) +
    ((parts[1]! << 16) >>> 0) +
    ((parts[2]! << 8) >>> 0) +
    (parts[3]! >>> 0)
  ) >>> 0;
}

function matchCidr(ip: string, cidr: string): boolean {
  const [net, bitsStr] = cidr.split("/");
  if (!net || bitsStr == null) return false;
  const bits = Number(bitsStr);
  if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false;
  const ipN = ipv4ToInt(ip);
  const netN = ipv4ToInt(net);
  if (ipN == null || netN == null) return false;
  if (bits === 0) return true;
  const mask = bits === 32 ? 0xffffffff : (~((1 << (32 - bits)) - 1)) >>> 0;
  return (ipN & mask) === (netN & mask);
}

/** True if clientIp is allowed. Empty allowlist = allow all. */
export function isIpAllowed(
  clientIp: string | null | undefined,
  allowlistRaw: string | null | undefined
): boolean {
  const entries = splitIpList(allowlistRaw || "");
  if (entries.length === 0) return true;
  if (!clientIp) return false;

  // First hop of X-Forwarded-For may include port rarely: strip
  const ip = clientIp.split("%")[0]!.trim();
  // IPv4-mapped IPv6
  const v4 = ip.startsWith("::ffff:") ? ip.slice(7) : ip;

  for (const entry of entries) {
    if (entry.includes("/")) {
      if (matchCidr(v4, entry)) return true;
    } else if (v4 === entry || ip === entry) {
      return true;
    }
  }
  return false;
}

/**
 * Client IP from reverse-proxy headers (nginx → Next).
 *
 * Trust model (production behind one proxy):
 * - Prefer X-Real-IP / CF-Connecting-IP set by the edge (not client-spoofable
 *   if the app is not directly exposed).
 * - Else use X-Forwarded-For from the right: drop TRUSTED_PROXY_HOPS trailing
 *   entries (default 1 = our nginx), take the next as client.
 * - Never trust a bare left-most XFF when the request might hit Node directly.
 */
export function getClientIpFromHeaders(headers: Headers): string | null {
  const real =
    headers.get("x-real-ip") ||
    headers.get("X-Real-IP") ||
    headers.get("cf-connecting-ip") ||
    headers.get("CF-Connecting-IP") ||
    null;
  if (real && real.trim()) {
    return normalizeIp(real.trim());
  }

  const xff =
    headers.get("x-forwarded-for") || headers.get("X-Forwarded-For") || "";
  if (xff) {
    const hops = xff
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    if (hops.length) {
      const trusted = Math.max(
        0,
        Number(process.env.TRUSTED_PROXY_HOPS || "1") || 1
      );
      // Client is the last untrusted hop
      const idx = Math.max(0, hops.length - 1 - trusted);
      const candidate = hops[idx] || hops[0];
      if (candidate) return normalizeIp(candidate);
    }
  }
  return null;
}

function normalizeIp(ip: string): string {
  let v = ip.split("%")[0]!.trim();
  // strip :port on IPv4
  if (/^\d+\.\d+\.\d+\.\d+:\d+$/.test(v)) {
    v = v.split(":")[0]!;
  }
  if (v.startsWith("::ffff:")) v = v.slice(7);
  return v;
}
