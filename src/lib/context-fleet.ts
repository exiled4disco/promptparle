/**
 * Context fleet: multi-agent style routing for docs, code, sheets, logs.
 *
 * Each part is compressed by the specialist that preserves the right fidelity
 * for that modality, then merged into one low-token packet.
 */

import {
  compressDocument,
  looksLikeDocument,
  leanMarkdownDocument,
} from "./document-compress";
import { compressCode, looksLikeCode } from "./code-compress";
import { compressSheet, looksLikeSheet } from "./sheet-compress";
import {
  detectContentKind,
  splitContextParts,
  type ContentKind,
  type ContextPart,
} from "./content-detect";
import { stripInlineDataUrls } from "./image-signal";
import {
  aggressivenessFor,
  normalizeCompressionLevel,
  type CompressionLevel,
} from "./compression-level";

export type FleetOptions = {
  prompt: string;
  profile: string;
  compressionLevel?: CompressionLevel | number;
};

export type FleetResult = {
  text: string;
  notes: string[];
  applied: boolean;
  strategy: string;
  signals: Record<string, number | string | boolean>;
};

function dedupeLines(text: string, aggressive: boolean): string {
  const lines = text.split("\n");
  const out: string[] = [];
  const counts = new Map<string, number>();
  let prev = "";
  for (const line of lines) {
    const normalized = line.trimEnd();
    if (normalized === prev && normalized.trim() !== "") continue;
    if (aggressive && normalized.trim()) {
      const key = normalized.trim();
      const c = (counts.get(key) || 0) + 1;
      counts.set(key, c);
      if (c > 2) continue;
    }
    out.push(line);
    prev = normalized;
  }
  return out.join("\n");
}

/**
 * High-fidelity log shrink: always keep ERROR/FATAL/Exception/stack frames;
 * drop DEBUG/TRACE spam and duplicate noise. Selection, not destruction.
 */
function compressLog(text: string, aggressive: boolean): {
  text: string;
  note?: string;
} {
  const before = text.length;
  const lines = text.split("\n");
  const out: string[] = [];
  const seen = new Map<string, number>();
  let contextWindow = 0;
  let keptErr = 0;
  let dropped = 0;
  const maxDup = aggressive ? 1 : 2;
  const errRe =
    /\b(ERROR|FATAL|CRITICAL|EXCEPTION|Traceback|FAILED|FAILURE|PANIC|Assert|npm ERR!|Build failed)\b/i;
  const stackRe =
    /^\s*(at\s+\S+\(|File\s+".+",\s*line\s+\d+|Caused by:|--- End of|\.\.\. \d+ more)/i;
  const noiseRe =
    /^\s*(\[?(DEBUG|TRACE|VERBOSE)\]?|console\.(log|debug))\b/i;
  const warnRe = /\bWARN(ING)?\b/i;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const trim = raw.trimEnd();
    const t = trim.trim();
    if (!t) {
      if (contextWindow > 0) {
        out.push("");
        contextWindow--;
      }
      continue;
    }

    const isErr = errRe.test(t) || stackRe.test(t);
    const isNoise = noiseRe.test(t);
    const isWarn = warnRe.test(t);

    if (isErr) {
      const key = t.length > 120 ? t.slice(0, 120) : t;
      const c = (seen.get(key) || 0) + 1;
      seen.set(key, c);
      if (c > maxDup) {
        dropped++;
        continue;
      }
      out.push(trim);
      keptErr++;
      contextWindow = aggressive ? 2 : 4;
      continue;
    }

    if (contextWindow > 0) {
      if (stackRe.test(t) || (!isNoise && t.length < 300)) {
        out.push(trim);
        if (stackRe.test(t)) contextWindow = Math.max(contextWindow, 2);
        else contextWindow--;
        continue;
      }
      dropped++;
      contextWindow--;
      continue;
    }

    if (isNoise) {
      dropped++;
      continue;
    }

    if (isWarn) {
      const wk = "W:" + (t.length > 80 ? t.slice(0, 80) : t);
      if (!seen.has(wk)) {
        seen.set(wk, 1);
        out.push(trim);
      } else dropped++;
      continue;
    }

    // INFO: keep sparse shape only when aggressive
    if (/^\s*\[?INFO\]?\b/i.test(t)) {
      if (!aggressive && i % 10 === 0) out.push(trim);
      else dropped++;
      continue;
    }

    // Non-log prose mixed in: light keep of short early lines
    if (!aggressive && t.length < 160 && i < 40) {
      out.push(trim);
    } else if (aggressive) {
      dropped++;
    } else {
      // fallback dedupe path for general lines
      const key = t;
      const c = (seen.get(key) || 0) + 1;
      seen.set(key, c);
      if (c > 2) dropped++;
      else out.push(trim);
    }
  }

  let result = out.join("\n");
  // Safety: if we destroyed almost everything, fall back to simple dedupe
  if (result.length < Math.min(200, before * 0.05) && before > 500) {
    result = dedupeLines(text, aggressive);
    return {
      text: result,
      note: aggressive
        ? "Log fleet: deduplicated repetitive lines"
        : "Log fleet: removed consecutive duplicates",
    };
  }

  result = result.replace(/\n{3,}/g, "\n\n");
  if (result.length < before) {
    return {
      text: result,
      note: `Log fleet: kept ${keptErr} error/stack signals, dropped ~${dropped} noise lines`,
    };
  }
  return { text: text };
}

function compressPart(
  part: ContextPart,
  opts: FleetOptions
): {
  text: string;
  notes: string[];
  strategy: string;
  stats: Record<string, number | string | boolean>;
  applied: boolean;
} {
  const prompt = opts.prompt;
  const profile = opts.profile;
  const dial = normalizeCompressionLevel(opts.compressionLevel);
  const aggro = aggressivenessFor(dial, profile);
  let kind = part.kind;

  // Refine mixed
  if (kind === "mixed" || kind === "empty") {
    if (looksLikeSheet(part.text, part.name)) kind = "sheet";
    else if (looksLikeCode(part.text, part.name)) kind = "code";
    else if (looksLikeDocument(part.text)) kind = "document";
    else if (detectContentKind(part.text, part.name) === "log") kind = "log";
  }

  if (kind === "sheet" || looksLikeSheet(part.text, part.name)) {
    const r = compressSheet(part.text, {
      prompt,
      name: part.name,
      maxSampleRows: aggro.sheetSampleRows,
    });
    if (r.applied) {
      return {
        text: r.text,
        notes: r.notes,
        strategy: r.strategy,
        stats: { ...r.stats, kind: "sheet", dial },
        applied: true,
      };
    }
  }

  if (kind === "code" || (part.name && looksLikeCode(part.text, part.name))) {
    const r = compressCode(part.text, {
      prompt,
      profile,
      language: part.language,
      name: part.name,
      targetRatio: aggro.codeTargetRatio,
    });
    if (r.applied) {
      return {
        text: r.text,
        notes: r.notes,
        strategy: r.strategy,
        stats: { ...r.stats, kind: "code", dial },
        applied: true,
      };
    }
  }

  if (
    kind === "document" ||
    (looksLikeDocument(part.text) && profile !== "log-analysis") ||
    (part.name && /\.(md|markdown|txt|rst)$/i.test(part.name))
  ) {
    const attemptNotes: string[] = [];
    const r = compressDocument(part.text, {
      prompt,
      profile,
      compressionLevel: dial,
    });
    attemptNotes.push(...(r.notes || []));
    if (r.applied) {
      return {
        text: r.text,
        notes: r.notes,
        strategy: r.strategy,
        stats: { ...r.stats, kind: "document", dial },
        applied: true,
      };
    }
    // Denser retry: executive nudge + lower keep ratio (dial 3+ often hits "brief grew")
    if (dial >= 2 && part.text.length >= 800) {
      const denserDial = Math.min(5, dial + 1) as 1 | 2 | 3 | 4 | 5;
      const r2 = compressDocument(part.text, {
        prompt,
        profile:
          profile === "general" || profile === "developer"
            ? "executive-summary"
            : profile,
        compressionLevel: denserDial,
        targetKeepRatio: denserDial >= 4 ? 0.22 : 0.32,
      });
      attemptNotes.push(...(r2.notes || []));
      if (r2.applied) {
        return {
          text: r2.text,
          notes: [
            "Document hybrid had no net savings; denser pass applied",
            ...r2.notes,
          ],
          strategy: r2.strategy || "signal-brief",
          stats: { ...r2.stats, kind: "document", dial: denserDial },
          applied: true,
        };
      }
    }
    // Structure-preserving markdown lean (tables/sections): last safe shrink
    if (part.text.length >= 600) {
      const lean = leanMarkdownDocument(part.text, {
        dial,
        targetRatio: dial <= 2 ? 0.65 : dial === 3 ? 0.42 : 0.28,
      });
      if (lean.text.length < part.text.length) {
        return {
          text: lean.text,
          notes: [
            ...attemptNotes.filter(Boolean),
            "Document brief skipped; md-lean applied",
            ...lean.notes,
          ],
          strategy: "md-lean",
          stats: {
            kind: "document",
            dial,
            keptBlocks: lean.keptBlocks,
            charsIn: part.text.length,
            charsOut: lean.text.length,
          },
          applied: true,
        };
      }
    }
    // Surface why we could not shrink (never silent "Fleet: no safe reduction")
    if (attemptNotes.length) {
      // fall through with notes carried into light cleanup
      const light = dedupeLines(part.text.replace(/\n{3,}/g, "\n\n"), false);
      if (light.length < part.text.length) {
        return {
          text: light,
          notes: [...attemptNotes, "Light whitespace/dedupe"],
          strategy: "lean",
          stats: { kind: kind || "document", dial },
          applied: true,
        };
      }
      return {
        text: part.text,
        notes: attemptNotes,
        strategy: "passthrough",
        stats: { kind: kind || "document", dial },
        applied: false,
      };
    }
  }

  if (kind === "log" || profile === "log-analysis") {
    const r = compressLog(
      part.text,
      aggro.aggressiveLogDedupe ||
        profile === "log-analysis" ||
        profile === "security-review"
    );
    if (r.note) {
      return {
        text: r.text,
        notes: [r.note],
        strategy: "log-dedupe",
        stats: { kind: "log" },
        applied: r.text.length < part.text.length,
      };
    }
  }

  // light cleanup fallback
  const light = dedupeLines(part.text.replace(/\n{3,}/g, "\n\n"), false);
  return {
    text: light,
    notes: light.length < part.text.length ? ["Light whitespace/dedupe"] : [],
    strategy: light.length < part.text.length ? "lean" : "passthrough",
    stats: { kind: kind || "mixed" },
    applied: light.length < part.text.length,
  };
}

/**
 * Run the context fleet over a (possibly multi-file) context blob.
 */
export function runContextFleet(
  context: string,
  opts: FleetOptions
): FleetResult {
  const notes: string[] = [];
  if (!context || !context.trim()) {
    return {
      text: context,
      notes: [],
      applied: false,
      strategy: "none",
      signals: {},
    };
  }

  // Strip accidental inline data-URLs from text channel
  const stripped = stripInlineDataUrls(context);
  notes.push(...stripped.notes);
  let working = stripped.text;

  const parts = splitContextParts(working);
  if (parts.length === 0) {
    return {
      text: working,
      notes,
      applied: false,
      strategy: "none",
      signals: {},
    };
  }

  const strategies = new Map<string, number>();
  const kindCounts: Record<string, number> = {};
  let anyApplied = false;
  let totalIn = 0;
  let totalOut = 0;
  const outChunks: string[] = [];

  // Header when multi-part
  const multi = parts.length > 1 || parts.some((p) => p.name);

  for (const part of parts) {
    totalIn += part.text.length;
    const k = part.kind as string;
    kindCounts[k] = (kindCounts[k] || 0) + 1;

    const result = compressPart(part, opts);
    notes.push(...result.notes);
    strategies.set(
      result.strategy,
      (strategies.get(result.strategy) || 0) + 1
    );
    if (result.applied) anyApplied = true;
    totalOut += result.text.length;

    if (multi && part.name) {
      outChunks.push(
        `===== FILE: ${part.name} · ${result.strategy} =====\n${result.text}`
      );
    } else if (multi) {
      outChunks.push(result.text);
    } else {
      outChunks.push(result.text);
    }
  }

  let merged = outChunks.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();

  // Fleet envelope when we actually compressed something multi-kind
  const usedStrategies = [...strategies.keys()].filter((s) => s !== "none");
  const primary =
    usedStrategies.length === 0
      ? "passthrough"
      : usedStrategies.length === 1
        ? usedStrategies[0]
        : "fleet";

  if (anyApplied && multi) {
    const dial = normalizeCompressionLevel(opts.compressionLevel);
    const map = parts
      .map((p, i) => {
        const label = p.name || `part-${i + 1}`;
        return `· ${label} (${p.kind})`;
      })
      .join("\n");
    const envelope = [
      "# CONTEXT FLEET",
      [
        `Parts: ${parts.length}`,
        `Strategies: ${usedStrategies.join(" + ") || "lean"}`,
        `Dial: ${dial}/5`,
        `Fidelity: per-modality specialists · high signal · low tokens`,
        `Ask: ${(opts.prompt || "").trim().replace(/\s+/g, " ").slice(0, 160) || "(general)"}`,
      ].join("\n"),
      "## Manifest\n" + map,
      "## Packets",
      merged,
    ].join("\n\n");
    // only use envelope if still smaller than original
    if (envelope.length < working.length) {
      merged = envelope;
    }
  }

  // Never expand
  if (merged.length >= working.length && !stripped.removed) {
    // try single-path document on whole blob as last resort if fleet grew
    if (looksLikeDocument(working) && opts.profile !== "log-analysis") {
      const doc = compressDocument(working, {
        prompt: opts.prompt,
        profile: opts.profile,
        compressionLevel: normalizeCompressionLevel(opts.compressionLevel),
      });
      if (doc.applied) {
        notes.push(...doc.notes);
        return {
          text: doc.text,
          notes,
          applied: true,
          strategy: doc.strategy || "signal-brief",
          signals: {
            ...doc.stats,
            fleetParts: parts.length,
            strategy: doc.strategy || "signal-brief",
          },
        };
      }
    }
    if (!anyApplied) {
      return {
        text: working,
        notes: notes.length ? notes : ["Fleet: no safe reduction"],
        applied: false,
        strategy: "none",
        signals: { fleetParts: parts.length },
      };
    }
  }

  if (merged.length >= working.length) {
    merged = working;
    anyApplied = stripped.removed > 0;
  }

  const savedPct =
    working.length > 0
      ? Math.round((1 - merged.length / working.length) * 100)
      : 0;

  if (anyApplied) {
    notes.push(
      `FLEET ${primary} −${savedPct}% chars · ${parts.length} part(s) · kinds: ${Object.entries(
        kindCounts
      )
        .map(([k, v]) => `${k}×${v}`)
        .join(", ")}`
    );
  }

  const signals: Record<string, number | string | boolean> = {
    fleetParts: parts.length,
    charsIn: totalIn,
    charsOut: totalOut,
    strategy: primary,
  };
  for (const [k, v] of Object.entries(kindCounts)) {
    signals[`kind_${k}`] = v;
  }
  for (const [s, n] of strategies) {
    if (s !== "none") signals[`strat_${s}`] = n;
  }

  return {
    text: merged,
    notes,
    applied: anyApplied || merged.length < working.length,
    strategy: primary === "passthrough" ? "lean" : primary,
    signals,
  };
}

export type { ContentKind, ContextPart };
