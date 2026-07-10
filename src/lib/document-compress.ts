/**
 * SIGNAL BRIEF — document intelligence for well-formed prose.
 *
 * Not "delete duplicate lines." We rebuild the document into a model-ready
 * briefing packet:
 *
 *  1) Strip chrome (TOC, page #, confidential banners)
 *  2) Parse outline + protect code fences
 *  3) Score every section against the user's question
 *  4) Mine hard requirements (must/shall/required…)
 *  5) Mine numbers, deadlines, $ / % / SLAs
 *  6) Keep query-matched evidence quotes
 *  7) Emit a structured SIGNAL BRIEF (smaller + smarter than raw prose)
 */

const STOP = new Set(
  `a an the and or but if in on at to for of as is are was were be been being
   this that these those it its with from by into about over after before
   between under again further then once here there when where why how all
   each few more most other some such no nor not only own same so than too
   very can will just don should now you your we our they their i me my
   please review document attached material give most useful findings first
   analyze summarize summary based following below above what are the`.split(
    /\s+/
  )
);

const HEDGE_INLINE =
  /\b(it is important to note that|please note that|as mentioned (above|earlier|previously),?\s*|in order to\s+|the purpose of this (section|document|paper) is to\s+|needless to say,?\s*|as you (may|might) (know|be aware),?\s*|for (all intents and purposes|the most part),?\s*|at the end of the day,?\s*|the following section describes\s+)/gi;

const PAGE_LINE =
  /^(page\s+\d+(\s+of\s+\d+)?|\d+\s*\/\s*\d+|[-–—]\s*\d+\s*[-–—])$/i;
const CONFIDENTIAL =
  /^(confidential|internal use only|do not distribute|proprietary and confidential|all rights reserved|copyright\s+©?\s*\d{4}).*$/i;
const TOC_HEADER = /^(table of contents|contents|index)$/i;

/** Imperative / obligation language — gold for policy & contracts */
const OBLIGATION =
  /\b(shall|must|must not|shall not|required to|are required|is required|prohibited|may not|cannot|will ensure|is responsible for|are responsible for|obligated to|mandatory)\b/i;

const NUMBERISH =
  /\b(\d{1,3}(?:,\d{3})*(?:\.\d+)?%?|\d+\s*(?:minutes?|hours?|days?|weeks?|months?|years?|seconds?)|\$\s?\d[\d,]*(?:\.\d+)?[kmb]?|\bSOC\s*2\b|\bISO\s*\d+\b|\bNIST\b[^\n,.]{0,40}|\b(?:MFA|VPN|SLA|RTO|RPO|PII|PHI)\b)/gi;

export type DocumentCompressOptions = {
  prompt: string;
  profile: string;
  targetKeepRatio?: number;
};

export type DocumentCompressResult = {
  text: string;
  notes: string[];
  applied: boolean;
  strategy: string;
  stats: {
    sections: number;
    paragraphsIn: number;
    paragraphsKept: number;
    outlineOnly: number;
    obligations: number;
    numbers: number;
    evidenceQuotes: number;
    skippedSections: number;
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

export function looksLikeDocument(text: string): boolean {
  if (!text || text.length < 500) return false;
  const lines = text.split("\n");
  const nonEmpty = lines.filter((l) => l.trim());
  if (nonEmpty.length < 4 && text.length < 1200) return false;

  const logHits = nonEmpty.filter((l) =>
    /^(ERROR|WARN|INFO|DEBUG|TRACE|ALERT|\[?\d{4}-\d{2}-\d{2})/i.test(l.trim())
  ).length;
  if (nonEmpty.length && logHits / nonEmpty.length > 0.4) return false;

  const hasHeadings = nonEmpty.some(
    (l) =>
      /^#{1,6}\s+\S/.test(l) ||
      (/^[A-Z][A-Za-z0-9 ,/&:-]{8,80}$/.test(l.trim()) &&
        l.trim().length < 80 &&
        !/[.!?]$/.test(l.trim()))
  );
  const hasParagraphs = nonEmpty.some((l) => l.trim().length > 100);
  const avgLen = nonEmpty.length
    ? nonEmpty.reduce((s, l) => s + l.trim().length, 0) / nonEmpty.length
    : 0;

  // Structured docs with headings win even if some filler lines repeat
  if (hasHeadings && text.length >= 500) return true;
  if (hasParagraphs && avgLen > 50 && text.length >= 800) return true;
  if (text.length > 2000 && avgLen > 40 && logHits / Math.max(1, nonEmpty.length) < 0.2)
    return true;

  return false;
}

function stripChrome(text: string): { text: string; removed: number } {
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
      if (
        /^(\d+(\.\d+)*\.?\s+).{2,80}\s+\d{1,4}$/.test(t) ||
        /^.+\s+[\.·…]{2,}\s*\d{1,4}$/.test(t) ||
        /^(\d+(\.\d+)*\.?\s+)[A-Z].{2,60}$/.test(t)
      ) {
        removed++;
        continue;
      }
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
    if (
      /^[A-Z0-9][A-Z0-9 \-/]{6,40}$/.test(t) &&
      t.length < 42 &&
      /CONFIDENTIAL|DRAFT|INTERNAL|COPYRIGHT|PROPRIETARY/.test(t)
    ) {
      removed++;
      continue;
    }

    out.push(raw);
  }

  return { text: out.join("\n"), removed };
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

    const md = /^(#{1,6})\s+(.+)$/.exec(t);
    if (md) {
      flushPara();
      blocks.push({ kind: "heading", text: md[2].trim(), level: md[1].length });
      i++;
      continue;
    }

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
  let s = text.replace(HEDGE_INLINE, "");
  s = s.replace(/\s*\((see|refer to|as shown in|optional|if applicable)[^)]{0,80}\)/gi, "");
  s = s.replace(/[ \t]{2,}/g, " ").replace(/\s+([,.;:!?])/g, "$1");
  const sentences = s.split(/(?<=[.!?])\s+/);
  const kept = sentences.filter((sent) => {
    const t = sent.trim();
    if (!t) return false;
    if (
      /^(furthermore|moreover|additionally|in conclusion|to summarize|in summary|as such|therefore|however|nevertheless|that said)\s*[.,]?$/i.test(
        t
      )
    )
      return false;
    return true;
  });
  return kept.join(" ").replace(/\s{2,}/g, " ").trim();
}

function scoreText(text: string, query: Set<string>): number {
  if (query.size === 0) return 0.2;
  const tokens = tokenize(text);
  if (tokens.length === 0) return 0;
  let hits = 0;
  const seen = new Set<string>();
  for (const t of tokens) {
    if (query.has(t) && !seen.has(t)) {
      hits += 1;
      seen.add(t);
    } else if (query.has(t)) {
      hits += 0.12;
    }
  }
  const coverage = hits / query.size;
  const density = hits / Math.sqrt(tokens.length);
  return coverage * 0.7 + density * 0.3;
}

function profileAggressiveness(profile: string): {
  maxObligations: number;
  maxEvidence: number;
  maxNumbers: number;
  evidenceSentences: number;
  keepCode: boolean;
} {
  switch (profile) {
    case "executive-summary":
      return {
        maxObligations: 12,
        maxEvidence: 4,
        maxNumbers: 10,
        evidenceSentences: 1,
        keepCode: false,
      };
    case "documentation":
      return {
        maxObligations: 20,
        maxEvidence: 8,
        maxNumbers: 16,
        evidenceSentences: 2,
        keepCode: true,
      };
    case "security-review":
      return {
        maxObligations: 24,
        maxEvidence: 10,
        maxNumbers: 18,
        evidenceSentences: 2,
        keepCode: true,
      };
    default:
      return {
        maxObligations: 16,
        maxEvidence: 6,
        maxNumbers: 14,
        evidenceSentences: 2,
        keepCode: true,
      };
  }
}

function splitSentences(text: string): string[] {
  return text
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function extractObligations(
  text: string,
  query: Set<string>,
  limit: number
): string[] {
  const sentences = splitSentences(text);
  const scored = sentences
    .filter((s) => OBLIGATION.test(s) && s.length > 20 && s.length < 420)
    .map((s) => ({
      s: densifyProse(s),
      score: scoreText(s, query) + (OBLIGATION.test(s) ? 0.25 : 0),
    }))
    .filter((x) => x.s.length > 15)
    .sort((a, b) => b.score - a.score);

  const out: string[] = [];
  const seen = new Set<string>();
  for (const x of scored) {
    const key = x.s.toLowerCase().slice(0, 80);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(x.s);
    if (out.length >= limit) break;
  }
  return out;
}

function extractNumbers(text: string, limit: number): string[] {
  const found: string[] = [];
  const seen = new Set<string>();
  // Prefer concrete SLA-style phrases first
  const preferred =
    text.match(
      /\b\d+\s*(?:minutes?|hours?|days?|weeks?|months?|years?|seconds?|characters?)\b|\b\$\s?\d[\d,]*(?:\.\d+)?[kmb]?\b|\b\d{1,3}%\b|\bSOC\s*2(?:\s*Type\s*II)?\b|\bNIST\s*SP\s*[\d-]+\b|\bISO\s*\d+\b|\b(?:MFA|VPN|RTO|RPO|PII|PHI|SOX)\b/gi
    ) || [];
  for (const raw of preferred) {
    const v = raw.replace(/\s+/g, " ").trim();
    const k = v.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    found.push(v);
    if (found.length >= limit) return found;
  }
  const re = new RegExp(NUMBERISH.source, "gi");
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const v = m[0].replace(/\s+/g, " ").trim();
    const k = v.toLowerCase();
    if (seen.has(k)) continue;
    if (/^\d{1,2}$/.test(v)) continue;
    if (/^\d{4}$/.test(v)) continue; // bare years
    if (/^\d{3}$/.test(v)) continue;
    seen.add(k);
    found.push(v);
    if (found.length >= limit) break;
  }
  return found;
}

function evidenceQuotes(
  sectionTitle: string,
  body: string,
  query: Set<string>,
  maxQuotes: number,
  sentencesPer: number
): { title: string; quotes: string[]; score: number } | null {
  const sentences = splitSentences(body);
  if (!sentences.length) return null;
  const ranked = sentences
    .map((s) => ({ s: densifyProse(s), score: scoreText(s, query) }))
    .filter((x) => x.s.length > 30)
    .sort((a, b) => b.score - a.score);

  const quotes: string[] = [];
  for (const x of ranked) {
    if (x.score < 0.12 && quotes.length > 0) continue;
    quotes.push(x.s);
    if (quotes.length >= Math.max(1, Math.min(sentencesPer, maxQuotes))) break;
  }
  if (!quotes.length) return null;
  const score = Math.max(...ranked.map((r) => r.score), 0);
  return { title: sectionTitle, quotes, score };
}

type Section = {
  heading?: { text: string; level: number };
  body: Block[];
  blob: string;
  score: number;
};

/**
 * Rebuild a well-formed document as a SIGNAL BRIEF.
 */
export function compressDocument(
  context: string,
  opts: DocumentCompressOptions
): DocumentCompressResult {
  const notes: string[] = [];
  const profile = opts.profile || "general";
  const emptyStats = {
    sections: 0,
    paragraphsIn: 0,
    paragraphsKept: 0,
    outlineOnly: 0,
    obligations: 0,
    numbers: 0,
    evidenceQuotes: 0,
    skippedSections: 0,
  };

  const forceProfile =
    profile === "documentation" || profile === "executive-summary";
  if (!looksLikeDocument(context) && !forceProfile) {
    return {
      text: context,
      notes: [],
      applied: false,
      strategy: "none",
      stats: emptyStats,
    };
  }
  if (context.length < 400) {
    return {
      text: context,
      notes: [],
      applied: false,
      strategy: "none",
      stats: emptyStats,
    };
  }

  const aggro = profileAggressiveness(profile);
  let text = context.replace(/\r\n/g, "\n");
  const chrome = stripChrome(text);
  text = chrome.text;
  if (chrome.removed > 0) {
    notes.push(`Stripped ${chrome.removed} chrome/TOC/banner lines`);
  }

  const query = keywordSet(opts.prompt || "");
  const blocks = splitBlocks(text);
  const paragraphsIn = blocks.filter((b) => b.kind === "para").length;

  // Sections
  const sections: Section[] = [];
  let cur: { heading?: { text: string; level: number }; body: Block[] } = {
    body: [],
  };

  const close = () => {
    if (!cur.heading && cur.body.length === 0) return;
    const blob = cur.body.map((b) => b.text).join("\n");
    const hScore = cur.heading ? scoreText(cur.heading.text, query) * 1.25 : 0;
    const bScore = scoreText(blob, query);
    sections.push({
      heading: cur.heading,
      body: cur.body,
      blob,
      score: Math.max(hScore, bScore),
    });
    cur = { body: [] };
  };

  for (const b of blocks) {
    if (b.kind === "heading") {
      close();
      cur = { heading: { text: b.text, level: b.level }, body: [] };
    } else {
      cur.body.push(b);
    }
  }
  close();

  if (sections.length === 1 && !sections[0].heading) {
    const only = sections[0];
    const expanded: Section[] = [];
    for (const b of only.body) {
      if (b.kind === "code") {
        expanded.push({ body: [b], blob: b.text, score: 0.45 });
      } else {
        expanded.push({
          body: [b],
          blob: b.text,
          score: scoreText(b.text, query),
        });
      }
    }
    sections.length = 0;
    sections.push(...expanded);
  }

  // Full-doc mines
  const allBlob = sections.map((s) => s.blob).join("\n");
  const obligations = extractObligations(
    allBlob,
    query,
    aggro.maxObligations
  );
  // Prefer obligations from high-score sections if we have many
  const numbers = extractNumbers(allBlob, aggro.maxNumbers);

  // Evidence from top sections
  const evidence: { title: string; quotes: string[]; score: number }[] = [];
  const rankedSections = [...sections].sort((a, b) => b.score - a.score);
  for (const s of rankedSections) {
    if (evidence.length >= aggro.maxEvidence) break;
    if (s.score < 0.1 && evidence.length >= 2) continue;
    const title = s.heading?.text || "Passage";
    const paras = s.body
      .filter((b) => b.kind === "para")
      .map((b) => b.text)
      .join(" ");
    if (!paras.trim()) continue;
    const ev = evidenceQuotes(
      title,
      paras,
      query,
      3,
      aggro.evidenceSentences
    );
    if (ev) evidence.push(ev);
  }

  // Code blocks from relevant sections
  const codeKeep: string[] = [];
  if (aggro.keepCode) {
    for (const s of rankedSections.slice(0, 4)) {
      for (const b of s.body) {
        if (b.kind === "code" && b.text.length < 4000) {
          codeKeep.push(b.text);
        }
      }
      if (codeKeep.length >= 2) break;
    }
  }

  // Map line
  const mapParts = rankedSections.map((s) => {
    const name = s.heading?.text || "body";
    let tag = "skip";
    if (s.score >= 0.35) tag = "keep";
    else if (s.score >= 0.15) tag = "lead";
    else if (s.heading) tag = "outline";
    const icon = tag === "keep" ? "✓" : tag === "lead" ? "~" : "·";
    return `${icon} ${name}`;
  });

  const skipped = sections.filter((s) => s.score < 0.15 && s.heading).length;
  const keptHigh = sections.filter((s) => s.score >= 0.35).length;

  // Build SIGNAL BRIEF
  const ask = (opts.prompt || "").trim().replace(/\s+/g, " ").slice(0, 200);
  const parts: string[] = [];

  parts.push("# SIGNAL BRIEF");
  parts.push(
    [
      `Ask: ${ask || "(general review)"}`,
      `Profile: ${profile}`,
      `Strategy: signal-brief (structure · obligations · numbers · evidence)`,
    ].join("\n")
  );

  if (mapParts.length) {
    parts.push(
      "## Map\n" +
        mapParts.slice(0, 24).join(" · ") +
        (mapParts.length > 24 ? " · …" : "")
    );
  }

  if (obligations.length) {
    parts.push(
      "## Hard requirements\n" +
        obligations.map((o) => `- ${o}`).join("\n")
    );
  }

  if (numbers.length) {
    parts.push(
      "## Numbers & deadlines\n" +
        numbers.map((n) => `\`${n}\``).join(" · ")
    );
  }

  if (evidence.length) {
    const evLines: string[] = ["## Evidence (query-matched)"];
    for (const e of evidence) {
      evLines.push(`### ${e.title}`);
      for (const q of e.quotes) {
        evLines.push(`> ${q}`);
      }
    }
    parts.push(evLines.join("\n"));
  }

  if (codeKeep.length) {
    parts.push("## Code\n" + codeKeep.join("\n\n"));
  }

  // Low-relevance inventory (builds trust — show what we dropped)
  const skippedNames = sections
    .filter((s) => s.score < 0.15 && s.heading)
    .map((s) => s.heading!.text);
  if (skippedNames.length) {
    parts.push(
      "## Deferred (low relevance to ask)\n" +
        skippedNames.slice(0, 16).map((n) => `- ${n}`).join("\n") +
        (skippedNames.length > 16
          ? `\n- …+${skippedNames.length - 16} more`
          : "")
    );
  }

  // Safety net: if almost no signal mined, fall back to densified top sections
  if (obligations.length < 2 && evidence.length < 2) {
    const fallback: string[] = ["## Key passages"];
    for (const s of rankedSections.slice(0, 5)) {
      if (s.heading) fallback.push(`### ${s.heading.text}`);
      const para = s.body.find((b) => b.kind === "para");
      if (para) {
        const d = densifyProse(
          splitSentences(para.text).slice(0, 3).join(" ")
        );
        if (d) fallback.push(d);
      }
    }
    parts.push(fallback.join("\n"));
    notes.push("Sparse obligation language — kept densified key passages");
  }

  let brief = parts.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();

  // Never expand
  if (brief.length >= context.length) {
    return {
      text: context,
      notes: ["Signal brief skipped (no net savings on this text)"],
      applied: false,
      strategy: "none",
      stats: { ...emptyStats, sections: sections.length, paragraphsIn },
    };
  }

  const savedPct = Math.round((1 - brief.length / context.length) * 100);
  notes.push(
    `SIGNAL BRIEF −${savedPct}% chars · ${obligations.length} requirements · ${numbers.length} numbers · ${evidence.length} evidence blocks · ${skipped} sections deferred`
  );
  notes.push(
    `Kept ${keptHigh} high-relevance sections; deferred low-relevance appendix/filler`
  );

  return {
    text: brief,
    notes,
    applied: true,
    strategy: "signal-brief",
    stats: {
      sections: sections.length,
      paragraphsIn,
      paragraphsKept: evidence.length,
      outlineOnly: skipped,
      obligations: obligations.length,
      numbers: numbers.length,
      evidenceQuotes: evidence.reduce((n, e) => n + e.quotes.length, 0),
      skippedSections: skipped,
    },
  };
}
