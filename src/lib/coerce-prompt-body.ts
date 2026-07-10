/**
 * Normalize desktop / browser JSON bodies before Zod.
 * PowerShell ConvertTo-Json and older clients sometimes send strings for
 * numbers/bools, null context, or char-array prompts — which used to 400
 * as a bare "Invalid request".
 */

const PROMPT_MAX = 500_000;
const CONTEXT_MAX = 2_000_000;

function asBool(v: unknown): boolean | undefined {
  if (typeof v === "boolean") return v;
  if (v === 1 || v === "1" || v === "true" || v === "True") return true;
  if (v === 0 || v === "0" || v === "false" || v === "False") return false;
  return undefined;
}

function asInt(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return Math.trunc(v);
  if (typeof v === "string" && v.trim() !== "" && !Number.isNaN(Number(v))) {
    return Math.trunc(Number(v));
  }
  return undefined;
}

function asString(v: unknown): string | undefined {
  if (v == null) return undefined;
  if (typeof v === "string") return v;
  if (Array.isArray(v)) {
    // PowerShell char[] / string[] accidents
    return v.map((x) => (typeof x === "string" ? x : String(x))).join("");
  }
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return undefined;
}

/** Mutates a shallow copy; safe to pass raw JSON. */
export function coercePromptBody(raw: unknown): Record<string, unknown> {
  const src =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  const b: Record<string, unknown> = { ...src };

  const prompt = asString(b.prompt);
  if (prompt != null) {
    b.prompt =
      prompt.length > PROMPT_MAX ? prompt.slice(0, PROMPT_MAX) : prompt;
  }

  // Native system / runtime (0.14.12+) — coerce strings, drop empties
  for (const k of [
    "system",
    "system_prompt",
    "systemPrompt",
    "runtime",
    "runtime_note",
    "runtimeNote",
  ] as const) {
    if (!(k in b)) continue;
    if (b[k] === null || b[k] === undefined) {
      delete b[k];
      continue;
    }
    const s = asString(b[k]);
    if (s == null || s.trim() === "") delete b[k];
    else b[k] = s.length > 50_000 ? s.slice(0, 50_000) : s;
  }

  if (b.context === null || b.context === undefined) {
    delete b.context;
  } else {
    const ctx = asString(b.context);
    if (ctx == null || ctx === "") {
      delete b.context;
    } else {
      b.context =
        ctx.length > CONTEXT_MAX ? ctx.slice(0, CONTEXT_MAX) : ctx;
    }
  }

  for (const k of [
    "compression_level",
    "compressionLevel",
    "max_tokens",
    "maxTokens",
  ] as const) {
    if (k in b) {
      const n = asInt(b[k]);
      if (n === undefined) delete b[k];
      else b[k] = n;
    }
  }

  for (const k of [
    "optimize_only",
    "optimizeOnly",
    "return_metadata",
    "returnMetadata",
  ] as const) {
    if (k in b) {
      const bo = asBool(b[k]);
      if (bo === undefined) delete b[k];
      else b[k] = bo;
    }
  }

  if (typeof b.provider === "string") {
    b.provider = b.provider.trim().toLowerCase();
  }

  if (typeof b.model === "string" && !b.model.trim()) {
    delete b.model;
  }

  // PowerShell often nests images as [[ {...}, {...} ]] after unary-comma + @()
  if ("images" in b) {
    b.images = flattenImageList(b.images);
    if (!Array.isArray(b.images) || b.images.length === 0) {
      delete b.images;
    }
  }

  return b;
}

/** Flatten nested image arrays and drop non-objects. */
function flattenImageList(raw: unknown): unknown[] {
  if (raw == null) return [];
  const out: Record<string, unknown>[] = [];

  const pushImg = (item: unknown) => {
    if (item == null) return;
    if (Array.isArray(item)) {
      // Nested array (PS accident) or rarely key/value pairs — recurse
      for (const x of item) pushImg(x);
      return;
    }
    if (typeof item !== "object") return;
    const o = item as Record<string, unknown>;
    // Skip DictionaryEntry-looking junk without payload
    const data =
      o.data_base64 ?? o.dataBase64 ?? o.data ?? o.Data_base64 ?? o.DataBase64;
    const media =
      o.media_type ?? o.mediaType ?? o.Media_type ?? o.MediaType ?? "image/png";
    if (data == null || data === "") return;
    out.push({
      media_type: typeof media === "string" ? media : "image/png",
      data_base64: typeof data === "string" ? data : String(data),
      ...(typeof o.name === "string" && o.name
        ? { name: o.name }
        : typeof o.Name === "string" && o.Name
          ? { name: o.Name }
          : {}),
    });
  };

  if (Array.isArray(raw)) {
    for (const item of raw) pushImg(item);
  } else {
    pushImg(raw);
  }

  return out.slice(0, 8);
}

export function formatZodDetails(err: {
  flatten: () => {
    formErrors: string[];
    fieldErrors: Record<string, string[] | undefined>;
  };
}): string {
  const f = err.flatten();
  const parts: string[] = [];
  for (const fe of f.formErrors || []) {
    if (fe) parts.push(fe);
  }
  for (const [k, msgs] of Object.entries(f.fieldErrors || {})) {
    if (msgs && msgs.length) parts.push(`${k}: ${msgs.join("; ")}`);
  }
  return parts.join(" · ") || "validation failed";
}
