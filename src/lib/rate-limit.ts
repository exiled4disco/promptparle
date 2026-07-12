/**
 * Process-local sliding-window rate limiter.
 * Good enough for single-node portal; pair with DB login lockout for auth.
 */

type Bucket = { timestamps: number[] };

const buckets = new Map<string, Bucket>();

export type RateLimitResult = {
  ok: boolean;
  remaining: number;
  retryAfterSec: number;
};

function prune(bucket: Bucket, windowMs: number, now: number) {
  const cutoff = now - windowMs;
  bucket.timestamps = bucket.timestamps.filter((t) => t > cutoff);
}

/** Limit `max` events per `windowMs` for a key (e.g. ip:login). */
export function checkRateLimit(
  key: string,
  max: number,
  windowMs: number
): RateLimitResult {
  const now = Date.now();
  let bucket = buckets.get(key);
  if (!bucket) {
    bucket = { timestamps: [] };
    buckets.set(key, bucket);
  }
  prune(bucket, windowMs, now);
  if (bucket.timestamps.length >= max) {
    const oldest = bucket.timestamps[0] ?? now;
    const retryAfterSec = Math.max(
      1,
      Math.ceil((oldest + windowMs - now) / 1000)
    );
    return { ok: false, remaining: 0, retryAfterSec };
  }
  bucket.timestamps.push(now);
  return {
    ok: true,
    remaining: Math.max(0, max - bucket.timestamps.length),
    retryAfterSec: 0,
  };
}

/** Rate-limit helper that does not consume a slot (peek). */
export function peekRateLimit(
  key: string,
  max: number,
  windowMs: number
): RateLimitResult {
  const now = Date.now();
  const bucket = buckets.get(key);
  if (!bucket) {
    return { ok: true, remaining: max, retryAfterSec: 0 };
  }
  prune(bucket, windowMs, now);
  if (bucket.timestamps.length >= max) {
    const oldest = bucket.timestamps[0] ?? now;
    const retryAfterSec = Math.max(
      1,
      Math.ceil((oldest + windowMs - now) / 1000)
    );
    return { ok: false, remaining: 0, retryAfterSec };
  }
  return {
    ok: true,
    remaining: Math.max(0, max - bucket.timestamps.length),
    retryAfterSec: 0,
  };
}

/** Occasional cleanup so the Map does not grow forever. */
export function sweepRateLimits(maxAgeMs = 3600_000) {
  const now = Date.now();
  for (const [k, b] of buckets) {
    prune(b, maxAgeMs, now);
    if (b.timestamps.length === 0) buckets.delete(k);
  }
}

// Presets used by routes
export const RL = {
  loginIp: { max: 30, windowMs: 15 * 60_000 },
  loginEmail: { max: 12, windowMs: 15 * 60_000 },
  registerIp: { max: 8, windowMs: 60 * 60_000 },
  resendIp: { max: 10, windowMs: 60 * 60_000 },
  oauthIp: { max: 40, windowMs: 15 * 60_000 },
  forgotIp: { max: 8, windowMs: 60 * 60_000 },
  forgotEmail: { max: 3, windowMs: 60 * 60_000 },
  resetIp: { max: 20, windowMs: 60 * 60_000 },
  changePasswordIp: { max: 15, windowMs: 60 * 60_000 },
  inviteRequestIp: { max: 6, windowMs: 60 * 60_000 },
  inviteRequestEmail: { max: 2, windowMs: 60 * 60_000 },
  v1PromptKey: { max: 120, windowMs: 60_000 },
  v1AgentKey: { max: 60, windowMs: 60_000 },
  v1GeneralKey: { max: 300, windowMs: 60_000 },
} as const;

export function rateLimitResponse(retryAfterSec: number, message?: string) {
  return {
    status: 429 as const,
    body: {
      error: message || "Too many requests. Slow down and try again.",
      retry_after: retryAfterSec,
    },
    headers: { "Retry-After": String(retryAfterSec) },
  };
}
