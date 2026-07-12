/**
 * CODE BRIEF: high-fidelity, low-token code compression.
 *
 * Keeps structure the model needs to reason (imports, signatures, matched bodies)
 * and drops comment noise, blank runs, and deep irrelevant function bodies.
 */

export type CodeCompressOptions = {
  prompt: string;
  profile?: string;
  language?: string;
  name?: string;
  /** soft keep ratio vs original chars */
  targetRatio?: number;
};

export type CodeCompressResult = {
  text: string;
  notes: string[];
  applied: boolean;
  strategy: string;
  stats: {
    linesIn: number;
    linesOut: number;
    units: number;
    unitsFull: number;
    unitsSigOnly: number;
    imports: number;
    commentsStripped: number;
  };
};

const STOP = new Set(
  `a an the and or but if in on at to for of as is are was were be been being
   this that these those it its with from by please review code file look
   analyze explain what how why fix bug issue function class`.split(/\s+/)
);

function tokenize(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9][a-z0-9\-_./]{1,}/g) || []).filter(
    (t) => !STOP.has(t) && t.length > 2
  );
}

type Unit = {
  kind: "import" | "export" | "type" | "function" | "class" | "block" | "other";
  name: string;
  header: string;
  body: string;
  startLine: number;
  score: number;
};

function stripComments(
  text: string,
  language?: string
): { text: string; stripped: number } {
  let stripped = 0;
  let out = text;

  // Preserve shebang
  const shebang = out.match(/^#![^\n]*\n/);
  const prefix = shebang ? shebang[0] : "";
  if (shebang) out = out.slice(prefix.length);

  // Block comments /* */  (not inside strings: good enough heuristic)
  out = out.replace(/\/\*[\s\S]*?\*\//g, (m) => {
    // keep license-ish short headers at top are already past first 2kb often
    if (/@license|copyright|SPDX/i.test(m) && m.length < 600) return m;
    // keep security markers
    if (/\b(TODO|FIXME|HACK|SECURITY|XXX|BUG)\b/.test(m)) {
      const keep = m
        .split("\n")
        .filter((l) => /\b(TODO|FIXME|HACK|SECURITY|XXX|BUG)\b/.test(l))
        .join("\n");
      stripped += m.length - keep.length;
      return keep;
    }
    stripped += m.length;
    return "";
  });

  // HTML/XML comments
  out = out.replace(/<!--[\s\S]*?-->/g, (m) => {
    stripped += m.length;
    return "";
  });

  const lineCommentLangs = new Set([
    "javascript",
    "typescript",
    "java",
    "c",
    "cpp",
    "csharp",
    "go",
    "rust",
    "php",
    "swift",
    "kotlin",
    "json",
  ]);
  const hashComment = new Set([
    "python",
    "bash",
    "ruby",
    "yaml",
    "toml",
    "r",
    "powershell",
    "dockerfile",
    "makefile",
  ]);

  const lines = out.split("\n");
  const kept: string[] = [];
  for (const line of lines) {
    const t = line.trim();
    // Keep TODO/FIXME line comments
    if (/\b(TODO|FIXME|HACK|SECURITY|XXX|BUG)\b/.test(t)) {
      kept.push(line);
      continue;
    }
    if (
      (language && lineCommentLangs.has(language) || !language) &&
      /^\s*\/\//.test(line)
    ) {
      stripped += line.length + 1;
      continue;
    }
    if (
      /^\s*#/.test(line) &&
      !/^\s*#!/.test(line) &&
      (language ? hashComment.has(language) : true) &&
      language !== "css" &&
      language !== "html"
    ) {
      // pure comment lines only (not YAML values that contain # mid-line)
      stripped += line.length + 1;
      continue;
    }
    // Inline // comments (conservative: only if not in URL)
    if (!language || lineCommentLangs.has(language) || language === "javascript" || language === "typescript") {
      const noUrl = line.replace(/https?:\/\/\S+/g, "URL");
      if (/\/\//.test(noUrl) && !/['"`].*\/\/.*['"`]/.test(noUrl)) {
        const idx = noUrl.indexOf("//");
        if (idx > 0) {
          const cut = line.slice(0, line.indexOf("//")).trimEnd();
          if (cut) {
            stripped += line.length - cut.length;
            kept.push(cut);
            continue;
          }
        }
      }
    }
    kept.push(line);
  }
  out = prefix + kept.join("\n");
  out = out.replace(/\n{3,}/g, "\n\n").trim() + (text.endsWith("\n") ? "\n" : "");
  return { text: out, stripped };
}

function scoreUnit(name: string, header: string, body: string, query: Set<string>): number {
  let s = 0.05;
  const blob = `${name} ${header} ${body.slice(0, 800)}`.toLowerCase();
  for (const q of query) {
    if (blob.includes(q)) s += 0.35;
  }
  if (/\b(error|exception|catch|throw|security|auth|password|token|inject|sql|xss|csrf|crypto|encrypt)\b/i.test(blob))
    s += 0.2;
  if (/\b(main|export default|module\.exports|public static void main)\b/i.test(header))
    s += 0.15;
  if (body.split("\n").length > 80) s += 0.05;
  return s;
}

/**
 * Lightweight unit split: group by top-level-ish declarations.
 * Not a full parser: good enough for token savings with signature preservation.
 */
function splitUnits(text: string, language?: string): Unit[] {
  const lines = text.split("\n");
  const units: Unit[] = [];
  let buf: string[] = [];
  let header = "";
  let kind: Unit["kind"] = "other";
  let name = "";
  let startLine = 1;
  let depth = 0;
  let started = false;

  const flush = (endLine: number) => {
    if (!buf.length && !header) return;
    const body = buf.join("\n");
    units.push({
      kind,
      name: name || kind,
      header: header || buf[0] || "",
      body,
      startLine,
      score: 0,
    });
    buf = [];
    header = "";
    kind = "other";
    name = "";
    startLine = endLine + 1;
    depth = 0;
    started = false;
  };

  const declRe =
    /^(\s*)(export\s+)?(default\s+)?(async\s+)?(function\*?|class|interface|type|enum|const|let|var|def|fn|func|pub\s+fn|public\s+class|private\s+class|package|import|from|using|namespace|#include|module)\b/;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const t = line.trim();
    const isImport =
      /^(import\s|from\s+\S+\s+import|using\s|package\s|#include|require\s*\()/.test(
        t
      );
    const isDecl = declRe.test(line);

    if (!started && (isImport || isDecl || t)) {
      started = true;
      startLine = i + 1;
      if (isImport) {
        kind = "import";
        name = "import";
      } else if (/\bclass\b/.test(t)) {
        kind = "class";
        name = (t.match(/\bclass\s+([A-Za-z0-9_]+)/) || [])[1] || "class";
      } else if (/\b(function\*?|def|fn|func)\b/.test(t) || /=>\s*\{?\s*$/.test(t)) {
        kind = "function";
        name =
          (t.match(/\bfunction\*?\s+([A-Za-z0-9_]+)/) ||
            t.match(/\bdef\s+([A-Za-z0-9_]+)/) ||
            t.match(/\bfn\s+([A-Za-z0-9_]+)/) ||
            t.match(/\bfunc\s+([A-Za-z0-9_]+)/) ||
            t.match(/\b(const|let|var)\s+([A-Za-z0-9_]+)/) ||
            [])[1] ||
          (t.match(/\b(const|let|var)\s+([A-Za-z0-9_]+)/) || [])[2] ||
          "fn";
      } else if (/\b(interface|type|enum)\b/.test(t)) {
        kind = "type";
        name = (t.match(/\b(?:interface|type|enum)\s+([A-Za-z0-9_]+)/) || [])[1] || "type";
      } else if (/^export\b/.test(t)) {
        kind = "export";
        name = "export";
      } else {
        kind = "block";
        name = t.slice(0, 40);
      }
      header = t;
    }

    buf.push(line);
    // brace depth for C-like; indent heuristic for python
    if (language === "python" || language === "yaml") {
      // flush on next top-level non-empty non-indent after a blank
      if (
        started &&
        i + 1 < lines.length &&
        lines[i + 1].trim() === "" &&
        i + 2 < lines.length &&
        /^\S/.test(lines[i + 2]) &&
        buf.length > 1
      ) {
        // peek - defer
      }
    } else {
      for (const ch of line) {
        if (ch === "{" || ch === "(") depth++;
        if (ch === "}" || ch === ")") depth = Math.max(0, depth - 1);
      }
    }

    const next = lines[i + 1];
    const atBoundary =
      next === undefined ||
      (depth === 0 &&
        started &&
        t !== "" &&
        (next.trim() === "" ||
          declRe.test(next) ||
          /^(import\s|from\s|using\s|package\s|#include)/.test(next.trim())));

    if (language === "python") {
      const nextTop =
        next !== undefined &&
        next.trim() !== "" &&
        !/^\s/.test(next) &&
        !next.trim().startsWith("#") &&
        buf.length >= 1 &&
        i > 0;
      if (nextTop && /^(def |class |@|async def |import |from )/.test(next.trim())) {
        flush(i);
        continue;
      }
    }

    if (atBoundary && started && (depth === 0 || language === "python")) {
      // don't flush single blank
      if (buf.some((b) => b.trim())) flush(i);
    }
  }
  if (buf.some((b) => b.trim())) flush(lines.length);

  // Merge tiny consecutive imports
  const merged: Unit[] = [];
  for (const u of units) {
    const prev = merged[merged.length - 1];
    if (prev && prev.kind === "import" && u.kind === "import") {
      prev.body = prev.body + "\n" + u.body;
      prev.header = "imports";
      prev.name = "imports";
      continue;
    }
    merged.push(u);
  }
  return merged;
}

function signatureOnly(unit: Unit, language?: string): string {
  const lines = unit.body.split("\n").filter((l, i, arr) => {
    // drop leading/trailing blank-only noise later
    return true;
  });
  if (unit.kind === "import") {
    return lines
      .map((l) => l.trimEnd())
      .filter((l) => l.trim())
      .join("\n");
  }

  const n = lines.filter((l) => l.trim()).length;
  const headerLine =
    lines.find((l) => l.trim() && !l.trim().startsWith("//") && !l.trim().startsWith("#")) ||
    unit.header;

  // Python: def/class line + ellipsis
  if (language === "python") {
    const sig = headerLine.trimEnd();
    const doc = lines.find((l) => /"""|'''/.test(l));
    const omit = Math.max(0, n - 1);
    if (doc) {
      return `${sig}\n    ${doc.trim()}\n    …  # ${omit} lines omitted (${unit.name})`;
    }
    return `${sig}\n    …  # ${omit} lines omitted (${unit.name})`;
  }

  // C-like: one signature line, optional `{ … }`
  const trimmedHeader = headerLine.trimEnd();
  if (/{\s*$/.test(trimmedHeader)) {
    return `${trimmedHeader} … } // ${n} lines (${unit.name})`;
  }
  if (lines.some((l) => l.includes("{"))) {
    return `${trimmedHeader} { … } // ${n} lines (${unit.name})`;
  }
  // types / one-liners
  if (n <= 2) return lines.map((l) => l.trimEnd()).join("\n");
  return `${trimmedHeader}\n// … ${n - 1} lines omitted (${unit.name})`;
}

function fullUnit(unit: Unit, maxChars: number): string {
  if (unit.body.length <= maxChars) return unit.body.trimEnd();
  const head = unit.body.slice(0, Math.floor(maxChars * 0.75));
  const tail = unit.body.slice(-Math.floor(maxChars * 0.15));
  return (
    head.trimEnd() +
    `\n// … truncated body (${unit.name}) …\n` +
    tail.trimStart()
  );
}

export function looksLikeCode(text: string, name?: string): boolean {
  if (!text || text.length < 40) return false;
  // reuse simple heuristics inline to avoid circular imports in tests
  const ext = (name || "").split(".").pop()?.toLowerCase() || "";
  const codeExt = new Set([
    "ts","tsx","js","jsx","py","go","rs","java","cs","php","rb","swift","kt",
    "c","h","cpp","ps1","psm1","sh","sql","vue","svelte",
  ]);
  if (codeExt.has(ext)) return true;
  const lines = text.split("\n").filter((l) => l.trim());
  if (lines.length < 3) return false;
  let hits = 0;
  for (const l of lines.slice(0, 40)) {
    if (
      /[{};]$/.test(l.trim()) ||
      /^(import |export |function |class |def |const |let |package |fn |func )/.test(
        l.trim()
      )
    )
      hits++;
  }
  return hits / Math.min(40, lines.length) > 0.25;
}

export function compressCode(
  source: string,
  opts: CodeCompressOptions
): CodeCompressResult {
  const notes: string[] = [];
  const emptyStats = {
    linesIn: 0,
    linesOut: 0,
    units: 0,
    unitsFull: 0,
    unitsSigOnly: 0,
    imports: 0,
    commentsStripped: 0,
  };
  if (!source || source.trim().length < 80) {
    return {
      text: source,
      notes: ["Code brief skipped (too small)"],
      applied: false,
      strategy: "none",
      stats: emptyStats,
    };
  }

  const linesIn = source.split("\n").length;
  const query = new Set(tokenize(opts.prompt || ""));
  const { text: stripped, stripped: commentsStripped } = stripComments(
    source,
    opts.language
  );
  if (commentsStripped > 40) {
    notes.push(`Stripped ~${commentsStripped} chars of comments`);
  }

  let units = splitUnits(stripped, opts.language);
  if (units.length < 2 && stripped.length < 400) {
    // just comment-stripped / whitespace collapse
    const compact = stripped.replace(/\n{3,}/g, "\n\n").trim();
    if (compact.length >= source.length * 0.95) {
      return {
        text: source,
        notes: ["Code already compact"],
        applied: false,
        strategy: "none",
        stats: { ...emptyStats, linesIn },
      };
    }
    notes.push("Code: comment/whitespace densify only");
    return {
      text: compact,
      notes,
      applied: true,
      strategy: "code-brief",
      stats: {
        linesIn,
        linesOut: compact.split("\n").length,
        units: 1,
        unitsFull: 1,
        unitsSigOnly: 0,
        imports: 0,
        commentsStripped,
      },
    };
  }

  for (const u of units) {
    u.score = scoreUnit(u.name, u.header, u.body, query);
  }

  const targetRatio =
    opts.targetRatio ?? (opts.profile === "developer" ? 0.42 : 0.35);
  const budget = Math.max(500, Math.floor(source.length * targetRatio));

  // Always keep imports full
  const imports = units.filter((u) => u.kind === "import");
  const rest = units.filter((u) => u.kind !== "import");
  const ranked = [...rest].sort((a, b) => b.score - a.score);

  // Cap full bodies tightly: high fidelity on what matters, sigs elsewhere
  const fullCap = Math.min(
    ranked.length,
    Math.max(1, query.size >= 2 ? 4 : 2),
    Math.ceil(ranked.length * 0.2) + (query.size >= 2 ? 2 : 1)
  );
  const fullSet = new Set<Unit>();
  for (const u of ranked) {
    if (fullSet.size >= fullCap) break;
    // prefer named functions/classes with any signal
    if (u.score >= 0.2 || u.kind === "class" || u.kind === "function") {
      fullSet.add(u);
    }
  }
  // always keep highest score full
  if (ranked[0]) fullSet.add(ranked[0]);
  for (const u of ranked) {
    if (u.score >= 0.55) fullSet.add(u);
  }

  const outParts: string[] = [];
  let used = 0;
  let unitsFull = 0;
  let unitsSigOnly = 0;

  for (const u of units) {
    if (u.kind === "import") {
      const block = u.body.trimEnd();
      outParts.push(block);
      used += block.length;
      continue;
    }
    let block: string;
    const wantFull = fullSet.has(u);
    if (wantFull && used < budget * 0.9) {
      block = fullUnit(u, Math.min(1800, Math.floor(budget * 0.4)));
      unitsFull++;
    } else {
      block = signatureOnly(u, opts.language);
      unitsSigOnly++;
    }
    if (used + block.length > budget && wantFull) {
      block = signatureOnly(u, opts.language);
      unitsFull = Math.max(0, unitsFull - 1);
      unitsSigOnly++;
    }
    outParts.push(block);
    used += block.length;
  }

  // If still over budget, demote remaining full bodies to signatures
  let body = outParts.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
  if (body.length > budget * 1.15) {
    const tight: string[] = [];
    unitsFull = 0;
    unitsSigOnly = 0;
    let keptFull = 0;
    for (const u of units) {
      if (u.kind === "import") {
        tight.push(u.body.trimEnd());
        continue;
      }
      if (fullSet.has(u) && keptFull < Math.max(1, fullCap - 1) && u.score >= ranked[0]?.score * 0.9) {
        tight.push(fullUnit(u, 1200));
        unitsFull++;
        keptFull++;
      } else {
        tight.push(signatureOnly(u, opts.language));
        unitsSigOnly++;
      }
    }
    body = tight.join("\n\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  const stats = {
    linesIn,
    linesOut: body.split("\n").length,
    units: units.length,
    unitsFull,
    unitsSigOnly,
    imports: imports.length,
    commentsStripped,
  };

  const brief = formatCodeBrief(opts, body, stats);
  // Prefer densified body alone if envelope would expand
  let finalText = brief;
  if (brief.length >= source.length && body.length < source.length * 0.95) {
    finalText = body;
    notes.push("CODE BRIEF envelope skipped (body-only densify)");
  }
  if (finalText.length >= source.length * 0.98) {
    // last resort: comments stripped only
    if (stripped.length < source.length * 0.95) {
      notes.push("Code: comment strip only (structure pass no net save)");
      return {
        text: stripped.replace(/\n{3,}/g, "\n\n").trim(),
        notes,
        applied: true,
        strategy: "code-brief",
        stats: {
          ...stats,
          linesOut: stripped.split("\n").length,
          unitsFull: 0,
          unitsSigOnly: 0,
        },
      };
    }
    return {
      text: source,
      notes: ["Code brief skipped (no net savings)"],
      applied: false,
      strategy: "none",
      stats: { ...emptyStats, linesIn },
    };
  }

  const savedPct = Math.round((1 - finalText.length / source.length) * 100);
  notes.push(
    `CODE BRIEF −${savedPct}% chars · ${unitsFull} full units · ${unitsSigOnly} signatures · ${imports.length} import blocks`
  );

  return {
    text: finalText,
    notes,
    applied: true,
    strategy: "code-brief",
    stats,
  };
}

function formatCodeBrief(
  opts: CodeCompressOptions,
  body: string,
  stats: CodeCompressResult["stats"]
): string {
  const name = opts.name || "code";
  const lang = opts.language || "unknown";
  const ask = (opts.prompt || "").trim().replace(/\s+/g, " ").slice(0, 160);
  return [
    "# CODE BRIEF",
    [
      `File: ${name}`,
      `Language: ${lang}`,
      `Ask: ${ask || "(general)"}`,
      `Fidelity: structure-complete · query-deep bodies`,
      `Stats: ${stats.linesIn}→${stats.linesOut} lines · full=${stats.unitsFull} · sig=${stats.unitsSigOnly}`,
    ].join("\n"),
    "## Structure map",
    `Imports kept · Full bodies for high-signal units · Signatures elsewhere (… lines omitted)`,
    "## Code",
    "```" + (lang !== "unknown" ? lang : ""),
    body,
    "```",
  ].join("\n\n");
}
