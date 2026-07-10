/**
 * Content-type detection for the context fleet.
 * Routes each chunk to the right high-fidelity compressor.
 */

export type ContentKind =
  | "code"
  | "document"
  | "sheet"
  | "log"
  | "mixed"
  | "empty";

export type ContextPart = {
  name?: string;
  text: string;
  kind: ContentKind;
  language?: string;
};

const CODE_EXT: Record<string, string> = {
  ts: "typescript",
  tsx: "typescript",
  js: "javascript",
  jsx: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  py: "python",
  go: "go",
  rs: "rust",
  java: "java",
  cs: "csharp",
  php: "php",
  rb: "ruby",
  swift: "swift",
  kt: "kotlin",
  kts: "kotlin",
  c: "c",
  h: "c",
  cpp: "cpp",
  hpp: "cpp",
  cc: "cpp",
  ps1: "powershell",
  psm1: "powershell",
  psd1: "powershell",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  sql: "sql",
  r: "r",
  vue: "vue",
  svelte: "svelte",
  html: "html",
  htm: "html",
  css: "css",
  scss: "css",
  less: "css",
  json: "json",
  yml: "yaml",
  yaml: "yaml",
  toml: "toml",
  xml: "xml",
  graphql: "graphql",
  gql: "graphql",
  proto: "protobuf",
  dockerfile: "dockerfile",
  makefile: "makefile",
};

const DOC_EXT = new Set([
  "md",
  "markdown",
  "rst",
  "txt",
  "adoc",
  "org",
  "tex",
  "rtf",
]);

const SHEET_EXT = new Set(["csv", "tsv", "tab"]);

const LOG_EXT = new Set(["log", "out", "err"]);

/** Parse multi-file context produced by local UI / PowerShell. */
export function splitContextParts(context: string): ContextPart[] {
  const text = (context || "").trim();
  if (!text) return [];

  // ===== FILE: name =====  or  ===== FILE (SSH): name =====  or  --- FILE: name ---
  const re =
    /(?:^|\n)(?:=====|---)\s*FILE(?:\s*\([^)]*\))?\s*:\s*(.+?)\s*(?:=====|---)\s*\n/gi;
  const markers: { name: string; index: number; headerEnd: number }[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    markers.push({
      name: m[1].trim(),
      index: m.index + (m[0].startsWith("\n") ? 1 : 0),
      headerEnd: m.index + m[0].length,
    });
  }

  if (markers.length === 0) {
    const kind = detectContentKind(text);
    return [{ text, kind, language: guessLanguage(undefined, text, kind) }];
  }

  const parts: ContextPart[] = [];
  // Leading free text before first FILE marker
  if (markers[0].index > 0) {
    const lead = text.slice(0, markers[0].index).trim();
    if (lead) {
      const kind = detectContentKind(lead);
      parts.push({
        text: lead,
        kind,
        language: guessLanguage(undefined, lead, kind),
      });
    }
  }

  for (let i = 0; i < markers.length; i++) {
    const start = markers[i].headerEnd;
    const end = i + 1 < markers.length ? markers[i + 1].index : text.length;
    const body = text.slice(start, end).trim();
    if (!body) continue;
    const name = markers[i].name;
    const kind = detectContentKind(body, name);
    parts.push({
      name,
      text: body,
      kind,
      language: guessLanguage(name, body, kind),
    });
  }
  return parts;
}

export function extOf(name?: string): string {
  if (!name) return "";
  const base = name.split(/[\\/]/).pop() || name;
  if (/^dockerfile$/i.test(base)) return "dockerfile";
  if (/^makefile$/i.test(base)) return "makefile";
  const i = base.lastIndexOf(".");
  if (i < 0) return "";
  return base.slice(i + 1).toLowerCase();
}

export function guessLanguage(
  name: string | undefined,
  text: string,
  kind: ContentKind
): string | undefined {
  const ext = extOf(name);
  if (ext && CODE_EXT[ext]) return CODE_EXT[ext];
  if (kind !== "code" && kind !== "mixed") return undefined;

  if (/^#!/.test(text)) {
    if (/python/.test(text.slice(0, 40))) return "python";
    if (/bash|sh/.test(text.slice(0, 40))) return "bash";
    if (/pwsh|powershell/.test(text.slice(0, 60))) return "powershell";
  }
  if (/\b(def |import |from \w+ import |class \w+\s*:)/.test(text))
    return "python";
  if (/\b(func |package |import \()\b/.test(text)) return "go";
  if (/\b(fn |let mut |impl |pub struct)\b/.test(text)) return "rust";
  if (/\b(function |const |let |export |import |=>)\b/.test(text))
    return "javascript";
  if (/\$\w+|Write-Host|param\s*\(/.test(text)) return "powershell";
  if (/\b(public class |namespace |using System)\b/.test(text)) return "csharp";
  return undefined;
}

export function detectContentKind(text: string, name?: string): ContentKind {
  if (!text || !text.trim()) return "empty";
  const ext = extOf(name);
  if (ext && SHEET_EXT.has(ext)) return "sheet";
  if (ext && LOG_EXT.has(ext)) return "log";
  if (ext && DOC_EXT.has(ext)) return "document";
  if (ext && CODE_EXT[ext]) return "code";

  const lines = text.split("\n");
  const nonEmpty = lines.filter((l) => l.trim());
  if (nonEmpty.length === 0) return "empty";

  // Log-heavy
  const logHits = nonEmpty.filter((l) =>
    /^(ERROR|WARN|INFO|DEBUG|TRACE|ALERT|\[?\d{4}-\d{2}-\d{2}|\[\d{2}:\d{2})/i.test(
      l.trim()
    )
  ).length;
  if (nonEmpty.length >= 5 && logHits / nonEmpty.length > 0.45) return "log";

  // Prose / docs first when markdown/outline is obvious (avoid CSV false positives)
  const hasHeadings = nonEmpty.some(
    (l) =>
      /^#{1,6}\s+\S/.test(l) ||
      (/^[A-Z][A-Za-z0-9 ,/&:-]{8,80}$/.test(l.trim()) &&
        l.trim().length < 80 &&
        !/[.!?]$/.test(l.trim()))
  );
  const avgLen =
    nonEmpty.reduce((s, l) => s + l.trim().length, 0) / nonEmpty.length;
  if (hasHeadings && text.length >= 200) return "document";

  // Spreadsheet / CSV (only when not clearly prose)
  if (looksLikeSheet(text)) return "sheet";

  // Code density
  const codeScore = scoreCodeDensity(text);
  if (codeScore >= 0.42) return "code";

  if (avgLen > 55 && text.length >= 600 && codeScore < 0.28) return "document";

  if (codeScore >= 0.28 && avgLen < 70) return "code";
  if (text.length > 1500) return "mixed";
  return codeScore > 0.22 ? "code" : "mixed";
}

function looksLikeSheet(text: string): boolean {
  const lines = text
    .split("\n")
    .map((l) => l.trimEnd())
    .filter((l) => l.trim());
  if (lines.length < 3) return false;
  const sample = lines.slice(0, Math.min(25, lines.length));

  const delimScores = [",", "\t", "|", ";"].map((d) => {
    const counts = sample.map((l) => (l.match(new RegExp(`\\${d === "|" ? "\\|" : d}`, "g")) || []).length);
    const nonzero = counts.filter((c) => c >= 1);
    if (nonzero.length < sample.length * 0.7) return 0;
    const mode = modeOf(nonzero);
    const consistency =
      nonzero.filter((c) => Math.abs(c - mode) <= 1).length / nonzero.length;
    return consistency * mode;
  });
  const best = Math.max(...delimScores);
  return best >= 2;
}

function modeOf(nums: number[]): number {
  const m = new Map<number, number>();
  for (const n of nums) m.set(n, (m.get(n) || 0) + 1);
  let best = nums[0];
  let bestC = 0;
  for (const [k, v] of m) {
    if (v > bestC) {
      best = k;
      bestC = v;
    }
  }
  return best;
}

function scoreCodeDensity(text: string): number {
  const lines = text.split("\n").filter((l) => l.trim());
  if (!lines.length) return 0;
  let hits = 0;
  for (const l of lines) {
    const t = l.trim();
    if (
      /[{};]$/.test(t) ||
      /^(import |from |export |package |using |#include|def |class |function |func |fn |const |let |var |public |private |protected |async |await |return |if \(|for \(|while \(|switch )/.test(
        t
      ) ||
      /=>|::|->|:=/.test(t) ||
      /^[@#]/.test(t) && t.length < 80 ||
      /^\s*(\/\/|#|\/\*|\*)/.test(l) ||
      /\$\w+\s*=/.test(t)
    ) {
      hits++;
    }
  }
  // symbol density bonus
  const symbols = (text.match(/[{}()[\];=<>]/g) || []).length;
  const symRatio = Math.min(1, symbols / Math.max(40, text.length / 20));
  return hits / lines.length * 0.75 + symRatio * 0.25;
}
