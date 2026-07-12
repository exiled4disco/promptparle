/**
 * Product system framing helpers.
 *
 * Desktop 0.14.12+ sends a separate `system` field (native role:system).
 * Older clients bake [SYS]/[RT]/[USER] into the user prompt: strip for
 * storage/usage so Before/After shows real user content, not the product brief.
 */

export type SplitFraming = {
  /** Static product brief (cacheable) */
  system: string;
  /** Per-turn runtime note (not cacheable) */
  runtime: string;
  /** User content only */
  user: string;
  /** True when [SYS]/[RT]/[USER] was extracted from a baked prompt */
  extracted: boolean;
};

const BAKED_RE =
  /^\[SYS\]\s*([\s\S]*?)\n\[RT\]\s*([\s\S]*?)\n\[USER\]\n([\s\S]*)$/;

/** Split baked framing if present; otherwise return prompt as user-only. */
export function splitBakedFraming(prompt: string): SplitFraming {
  const p = (prompt || "").replace(/^\uFEFF/, "");
  const m = BAKED_RE.exec(p.trimEnd());
  if (!m) {
    return { system: "", runtime: "", user: p, extracted: false };
  }
  return {
    system: (m[1] || "").trim(),
    runtime: (m[2] || "").trim(),
    user: m[3] || "",
    extracted: true,
  };
}

/**
 * Resolve system + user for the provider call and for usage storage.
 * Prefer explicit system/system_prompt fields; fall back to baked tags.
 */
export function resolveSystemAndUser(opts: {
  prompt: string;
  system?: string | null;
  runtime?: string | null;
}): {
  system: string;
  runtime: string;
  userPrompt: string;
  /** Text to store as "before" (never includes product [SYS] essay) */
  storagePrompt: string;
} {
  const explicitSystem = (opts.system || "").trim();
  const explicitRuntime = (opts.runtime || "").trim();

  if (explicitSystem || explicitRuntime) {
    return {
      system: explicitSystem,
      runtime: explicitRuntime,
      userPrompt: opts.prompt,
      storagePrompt: opts.prompt,
    };
  }

  const split = splitBakedFraming(opts.prompt);
  if (split.extracted) {
    return {
      system: split.system,
      runtime: split.runtime,
      userPrompt: split.user,
      storagePrompt: split.user,
    };
  }

  return {
    system: "",
    runtime: "",
    userPrompt: opts.prompt,
    storagePrompt: opts.prompt,
  };
}

/** Combine static system + runtime for providers that only accept one system string. */
export function combineSystemMessage(
  system: string,
  runtime?: string
): string | undefined {
  const s = (system || "").trim();
  const r = (runtime || "").trim();
  if (!s && !r) return undefined;
  if (!s) return r;
  if (!r) return s;
  return `${s}\n\n[RT] ${r}`;
}
