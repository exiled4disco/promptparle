/**
 * Document-aware compression for well-formed prose (not log dedupe).
 *
 * Strategies (stacked):
 *  1) Strip document chrome (TOC, page numbers, confidentiality banners)
 *  2) Protect fenced code blocks
 *  3) Split into outline sections + paragraphs
 *  4) Query-aware scoring vs the user prompt (keep what answers the ask)
 *  5) Densify prose (hedges, empty transitions, parenthetical filler)
 *  6) Emit: outline + high-signal excerpts (profile sets aggressiveness)
 */

const STOP = new Set(
  `a an the and or but if in on at to for of as is are was were be been being
   this that these those it its with from by into about over after before
   between under again further then once here there when where why how all
   each few more most other some such no nor not only own same so than too
   very can will just don should now you your we our they their i me my
   please review document attached material give most useful findings first
   analyze summarize summary based following below above`.split(/\s+/)
);

const HEDGE =
  /^(it is (important|worth|critical|essential) to (note|mention|remember) that\s+)/i;
const HEDGE_INLINE =
  /\b(it is important to note that|please note that|as mentioned (above|earlier|previously),?\s*|in order to\s+|the purpose of this (section|document|paper) is to\s+|needless to say,?\s*|as you (may|might) (know|be aware),?\s*|for (all intents and purposes|the most part),?\s*|at the end of the day,?\s*)/gi;

const TRANSITION_ONLY =
  /^(furthermore|moreover|additionally|in conclusion|to summarize|in summary|as such|therefore|however|nevertheless|that said|with that in mind|moving on|next,|first,|second,|third,|finally,)\s*$/i;

const PAGE_LINE =
  /^(page\s+\d+(\s+of\s+\d+)?|\d+\s*\/\s*\d+|[-–—]\s*\d+\s*[-–—])$/i;
const CONFIDENTIAL =
  /^(confidential|internal use only|do not distribute|proprietary and confidential|all rights reserved|copyright\s+©?\s*\d{4}).*$/i;
const TOC_HEADER = /^(table of contents|contents|index)$/i;

export type DocumentCompressOptions = {
  prompt: string;
  profile: string;
  /** soft target fraction of original context chars to keep (0–1) */
  targetKeepRatio?: number;
};

export type DocumentCompressResult = {
  text: string;
  notes: string[];
  /** true when we treated input as a document and applied doc pipeline */
  applied: boolean;
  stats: {
    sections: number;
    paragraphsIn: number;
    paragraphsKept: number;
    outlineOnly: number;
  };
};

function tokenize(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9][a-z0-9\-_./]{1,}/g) || []).filter(
    (t) => !STOP.has(t) && t.length > 2
  );
}

function keywordSet(text: string): Set<string> {
  return new Set(tokenize(text));
}

/** Heuristic: well-formed document vs log dump / code-only. */
export function looksLikeDocument(text: string): boolean {
  if (!text || text.length < 600) return false;
  const lines = text.split("\n");
  if (lines.length < 8) {
    // long single blob of prose
    return text.length > 1200 && !/^(ERROR|WARN|INFO|DEBUG)\b/m.test(text);
  }

  const nonEmpty = lines.filter((l) => l.trim());
  if (nonEmpty.length < 5) return false;

  // Log-like: many short similar-prefix lines
  const logHits = nonEmpty.filter((l) =>
    /^(ERROR|WARN|INFO|DEBUG|TRACE|ALERT|\[?\d{4}-\d{2}-\d{2})/i.test(l.trim())
  ).length;
  if (logHits / nonEmpty.length > 0.35) return false;

  // High exact-line duplication → log/noise path, not document path
  const counts = new Map<string, number>();
  for (const l of nonEmpty) {
    const k = l.trim();
    counts.set(k, (counts.get(k) || 0) + 1);
  }
  let dupes = 0;
  for (const c of counts.values()) {
    if (c > 1) dupes += c - 1;
  }
  if (dupes / nonEmpty.length > 0.25) return false;

  const avgLen =
    nonEmpty.reduce((s, l) => s + l.trim().length, 0) / nonEmpty.length;
  const hasHeadings = nonEmpty.some(
    (l) =>
      /^#{1,6}\s+\S/.test(l) ||
      (/^[A-Z][A-Za-z0-9 ,/&:-]{8,80}$/.test(l.trim()) &&
        l.trim().length < 80 &&
        !/[.!?]$/.test(l.trim()))
  );
  const hasParagraphs = nonEmpty.some((l) => l.trim().length > 120);

  return avgLen > 40 || hasHeadings || hasParagraphs;
}

function stripChrome(text: string, notes: string[]): string {
  const lines = text.split("\n");
  const out: string[] = [];
  let inToc = false;
  let removed = 0;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const t = raw.trim();

    if (TOC_HEADER.test(t)) {
      inToc = true;
      removed++;
      continue;
    }
    if (inToc) {
      // TOC entries: "1. Foo .... 12" or "Foo ........ 3"
      if (
        /^(\d+(\.\d+)*\.?\s+).{2,80}\s+\d{1,4}$/.test(t) ||
        /^.+\s+[\.·…]{2,}\s*\d{1,4}$/.test(t) ||
        /^(\d+(\.\d+)*\.?\s+)[A-Z].{2,60}$/.test(t)
      ) {
        removed++;
        continue;
      }
      // leave TOC when we hit a real heading/paragraph
      if (t.length > 90 || /^#{1,6}\s/.test(t) || /^[A-Z][a-z].+\.$/.test(t)) {
        inToc = false;
      } else if (!t) {
        continue;
      } else {
        removed++;
        continue;
      }
    }

    if (PAGE_LINE.test(t) || CONFIDENTIAL.test(t)) {
      removed++;
      continue;
    }
    // Running header/footer echoes (very short ALL CAPS repeated style)
    if (/^[A-Z0-9][A-Z0-9 \-/]{6,40}$/.test(t) && t.length < 42) {
      // keep if it looks like a real section title (handled later); drop pure banners
      if (/CONFIDENTIAL|DRAFT|INTERNAL|COPYRIGHT|PROPRIETARY/.test(t)) {
        removed++;
        continue;
      }
    }

    out.push(raw);
  }

  if (removed > 0) {
    notes.push(`Removed ${removed} chrome/TOC/page-banner lines`);
  }
  return out.join("\n");
}

type Block =
  | { kind: "code"; text: string }
  | { kind: "heading"; text: string; level: number }
  | { kind: "para"; text: string };

function splitBlocks(text: string): Block[] {
  const blocks: Block[] = [];
  const lines = text.split("\n");
  let i = 0;
  let paraBuf: string[] = [];

  const flushPara = () => {
    const p = paraBuf.join("\n").trim();
    paraBuf = [];
    if (p) blocks.push({ kind: "para", text: p });
  };

  while (i < lines.length) {
    const line = lines[i];

    // fenced code
    if (/^```/.test(line.trim())) {
      flushPara();
      const buf = [line];
      i++;
      while (i < lines.length && !/^```/.test(lines[i].trim())) {
        buf.push(lines[i]);
        i++;
      }
      if (i < lines.length) buf.push(lines[i]);
      blocks.push({ kind: "code", text: buf.join("\n") });
      i++;
      continue;
    }

    const t = line.trim();
    if (!t) {
      flushPara();
      i++;
      continue;
    }

    // markdown heading
    const md = /^(#{1,6})\s+(.+)$/.exec(t);
    if (md) {
      flushPara();
      blocks.push({ kind: "heading", text: md[2].trim(), level: md[1].length });
      i++;
      continue;
    }

    // underline heading (Setext) - rare
    if (
      i + 1 < lines.length &&
      /^=+$/.test(lines[i + 1].trim()) &&
      t.length > 2 &&
      t.length < 100
    ) {
      flushPara();
      blocks.push({ kind: "heading", text: t, level: 1 });
      i += 2;
      continue;
    }
    if (
      i + 1 < lines.length &&
      /^-+$/.test(lines[i + 1].trim()) &&
      t.length > 2 &&
      t.length < 100
    ) {
      flushPara();
      blocks.push({ kind: "heading", text: t, level: 2 });
      i += 2;
      continue;
    }

    // ALL CAPS / Title Case short line as heading if next is body
    if (
      t.length >= 8 &&
      t.length <= 90 &&
      !/[.!?]$/.test(t) &&
      !/^[-*•\d]/.test(t) &&
      (/^[A-Z0-9][A-Z0-9 ,/&():-]{7,}$/.test(t) ||
        (/^[A-Z][A-Za-z0-9 ,/&():-]+$/.test(t) &&
          t.split(/\s+/).length <= 12 &&
          i + 1 < lines.length &&
          lines[i + 1].trim().length > 40))
    ) {
      flushPara();
      blocks.push({
        kind: "heading",
        text: t,
        level: /^[A-Z0-9 ,/&():-]+$/.test(t) ? 2 : 3,
      });
      i++;
      continue;
    }

    paraBuf.push(line);
    i++;
  }
  flushPara();
  return blocks;
}

function densifyProse(text: string): string {
  let s = text;
  s = s.replace(HEDGE_INLINE, "");
  s = s.replace(HEDGE, "");
  // parenthetical asides that are pure meta
  s = s.replace(/\s*\((see|refer to|as shown in|optional|if applicable)[^)]{0,80}\)/gi, "");
  // multi-space / space before punct
  s = s.replace(/[ \t]{2,}/g, " ");
  s = s.replace(/\s+([,.;:!?])/g, "$1");

  // Drop transition-only sentences
  const sentences = s.split(/(?<=[.!?])\s+/);
  const kept = sentences.filter((sent) => {
    const t = sent.trim();
    if (!t) return false;
    if (TRANSITION_ONLY.test(t)) return false;
    if (/^(this section (will|describes|provides)|the following (section|chapter))/i.test(t) && t.length < 100)
      return false;
    return true;
  });
  return kept.join(" ").replace(/\s{2,}/g, " ").trim();
}

function scoreText(text: string, query: Set<string>): number {
  if (query.size === 0) return 0.15; // mild base so structure still ranks
  const tokens = tokenize(text);
  if (tokens.length === 0) return 0;
  let hits = 0;
  const seen = new Set<string>();
  for (const t of tokens) {
    if (query.has(t) && !seen.has(t)) {
      hits += 1;
      seen.add(t);
    } else if (query.has(t)) {
      hits += 0.15;
    }
  }
  // density of unique query hits
  const coverage = hits / query.size;
  const density = hits / Math.sqrt(tokens.length);
  // prefer medium paragraphs over tiny crumbs
  const lengthBonus = Math.min(1, text.length / 400) * 0.1;
  return coverage * 0.65 + density * 0.35 + lengthBonus;
}

function profileTargetRatio(profile: string): number {
  switch (profile) {
    case "executive-summary":
      return 0.28;
    case "documentation":
      return 0.42;
    case "developer":
      return 0.55;
    case "security-review":
      return 0.5;
    default:
      return 0.45;
  }
}

function firstSentences(text: string, n: number): string {
  const parts = text.split(/(?<=[.!?])\s+/).filter((s) => s.trim());
  if (parts.length <= n) return text.trim();
  return parts.slice(0, n).join(" ").trim();
}

/**
 * Compress a well-formed document relative to the user question.
 */
export function compressDocument(
  context: string,
  opts: DocumentCompressOptions
): DocumentCompressResult {
  const notes: string[] = [];
  const profile = opts.profile || "general";
  const targetRatio = opts.targetKeepRatio ?? profileTargetRatio(profile);

  if (!looksLikeDocument(context) && profile !== "documentation" && profile !== "executive-summary") {
    return {
      text: context,
      notes: [],
      applied: false,
      stats: { sections: 0, paragraphsIn: 0, paragraphsKept: 0, outlineOnly: 0 },
    };
  }

  let text = context.replace(/\r\n/g, "\n");
  text = stripChrome(text, notes);

  const query = keywordSet(opts.prompt || "");
  const blocks = splitBlocks(text);

  // Group into sections: heading + following body blocks until next heading
  type Section = {
    heading?: { text: string; level: number };
    body: Block[];
    score: number;
  };
  const sections: Section[] = [];
  let cur: Section = { body: [], score: 0 };

  const close = () => {
    if (!cur.heading && cur.body.length === 0) return;
    const blob = cur.body.map((b) => b.text).join("\n");
    const hScore = cur.heading ? scoreText(cur.heading.text, query) * 1.2 : 0;
    cur.score = Math.max(hScore, scoreText(blob, query));
    sections.push(cur);
    cur = { body: [], score: 0 };
  };

  for (const b of blocks) {
    if (b.kind === "heading") {
      close();
      cur = { heading: { text: b.text, level: b.level }, body: [], score: 0 };
    } else {
      cur.body.push(b);
    }
  }
  close();

  // If no headings, treat each para as its own section
  if (sections.length === 1 && !sections[0].heading) {
    const only = sections[0];
    const expanded: Section[] = [];
    for (const b of only.body) {
      if (b.kind === "code") {
        expanded.push({ body: [b], score: 0.5 });
      } else {
        expanded.push({
          body: [b],
          score: scoreText(b.text, query),
        });
      }
    }
    sections.length = 0;
    sections.push(...expanded);
  }

  const paragraphsIn = blocks.filter((b) => b.kind === "para").length;
  const origChars = text.length;
  const budget = Math.max(400, Math.floor(origChars * targetRatio));

  // Sort body content by score but emit in document order
  const scored = sections.map((s, idx) => ({ s, idx, score: s.score }));
  const rankOrder = [...scored].sort((a, b) => b.score - a.score);

  // Always keep top section and any with code
  const keepFull = new Set<number>();
  const keepLead = new Set<number>(); // first sentence / short lead only
  const outlineOnly = new Set<number>();

  // Seed: best sections until budget roughly satisfied
  let used = 0;
  for (const { s, idx, score } of rankOrder) {
    const bodyText = s.body.map((b) => b.text).join("\n");
    const hasCode = s.body.some((b) => b.kind === "code");
    const est = (s.heading?.text.length || 0) + bodyText.length;

    if (hasCode || score >= 0.35 || keepFull.size < 2) {
      keepFull.add(idx);
      used += est;
    } else if (score >= 0.18 && used < budget) {
      keepFull.add(idx);
      used += est;
    } else if (s.heading && score >= 0.08) {
      keepLead.add(idx);
      used += (s.heading.text.length || 0) + 120;
    } else if (s.heading) {
      outlineOnly.add(idx);
      used += s.heading.text.length + 4;
    } else if (score >= 0.12 && used < budget) {
      keepLead.add(idx);
      used += Math.min(est, 200);
    }
  }

  // Trim if still over budget: demote lowest full sections to lead/outline
  const fullRanked = [...keepFull].sort(
    (a, b) => sections[a].score - sections[b].score
  );
  while (used > budget * 1.15 && fullRanked.length > 2) {
    const idx = fullRanked.shift()!;
    keepFull.delete(idx);
    const bodyText = sections[idx].body.map((b) => b.text).join("\n");
    used -= bodyText.length * 0.7;
    if (sections[idx].heading) keepLead.add(idx);
    else outlineOnly.add(idx);
  }

  // Build output in original order
  const outParts: string[] = [];
  let paragraphsKept = 0;
  let outlineOnlyCount = 0;

  // Optional mini-outline at top when we drop a lot
  const droppedBodies = sections.filter(
    (_, i) => !keepFull.has(i) && (outlineOnly.has(i) || keepLead.has(i))
  ).length;
  if (droppedBodies >= 3) {
    const outline = sections
      .filter((s) => s.heading)
      .map((s) => `${"#".repeat(Math.min(s.heading!.level, 4))} ${s.heading!.text}`)
      .join("\n");
    if (outline) {
      outParts.push("## Document outline\n" + outline);
      notes.push("Added compact section outline");
    }
  }

  for (let idx = 0; idx < sections.length; idx++) {
    const s = sections[idx];
    const head = s.heading
      ? `${"#".repeat(Math.min(s.heading.level, 4))} ${s.heading.text}`
      : null;

    if (keepFull.has(idx)) {
      if (head) outParts.push(head);
      for (const b of s.body) {
        if (b.kind === "code") {
          outParts.push(b.text);
        } else {
          const d = densifyProse(b.text);
          if (d) {
            outParts.push(d);
            paragraphsKept++;
          }
        }
      }
    } else if (keepLead.has(idx)) {
      if (head) outParts.push(head);
      const paras = s.body.filter((b) => b.kind === "para");
      const codes = s.body.filter((b) => b.kind === "code");
      for (const c of codes) outParts.push(c.text);
      if (paras.length) {
        const lead = densifyProse(firstSentences(paras[0].text, 2));
        if (lead) {
          outParts.push(lead + (paras.length > 1 || paras[0].text.length > lead.length + 40 ? " …" : ""));
          paragraphsKept++;
        }
      }
    } else if (outlineOnly.has(idx) && head) {
      // heading already in top outline; skip duplicate unless no top outline
      if (droppedBodies < 3) {
        outParts.push(head);
        outlineOnlyCount++;
      } else {
        outlineOnlyCount++;
      }
    }
  }

  let compressed = outParts.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();

  // Hard ceiling: if still huge, pack by score globally
  if (compressed.length > budget * 1.25) {
    const pieces = outParts.map((p, i) => ({
      p,
      i,
      score: scoreText(p, query),
    }));
    pieces.sort((a, b) => b.score - a.score);
    const kept: string[] = [];
    let u = 0;
    const chosen = new Set<number>();
    for (const x of pieces) {
      if (u >= budget && kept.length >= 4) break;
      chosen.add(x.i);
      u += x.p.length;
    }
    compressed = outParts
      .filter((_, i) => chosen.has(i))
      .join("\n\n")
      .trim();
    notes.push("Packed to target budget by relevance to your question");
  }

  const savedPct =
    origChars > 0
      ? Math.round((1 - compressed.length / origChars) * 100)
      : 0;
  if (savedPct > 0) {
    notes.push(
      `Document compress ~${savedPct}% (query-aware sections, densify, chrome strip)`
    );
  } else {
    notes.push("Document pipeline ran but found little safe to drop");
  }

  // Never return larger than input
  if (compressed.length >= context.length) {
    return {
      text: context,
      notes: ["Document compress skipped (no net savings)"],
      applied: false,
      stats: {
        sections: sections.length,
        paragraphsIn,
        paragraphsKept: paragraphsIn,
        outlineOnly: 0,
      },
    };
  }

  return {
    text: compressed,
    notes,
    applied: true,
    stats: {
      sections: sections.length,
      paragraphsIn,
      paragraphsKept,
      outlineOnly: outlineOnlyCount,
    },
  };
}
