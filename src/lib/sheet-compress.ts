/**
 * SHEET CARD — high-fidelity spreadsheet/CSV compression.
 * Models get schema + stats + stratified samples, not 50k raw rows.
 */

export type SheetCompressOptions = {
  prompt: string;
  name?: string;
  maxSampleRows?: number;
  maxCols?: number;
};

export type SheetCompressResult = {
  text: string;
  notes: string[];
  applied: boolean;
  strategy: string;
  stats: {
    rows: number;
    cols: number;
    sampleRows: number;
    matchedRows: number;
    delimiter: string;
  };
};

const STOP = new Set(
  `a an the and or but if in on at to for of as is are was were be been
   this that these those please review sheet spreadsheet csv table data
   show list what which how`.split(/\s+/)
);

function tokenize(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9][a-z0-9\-_./]{1,}/g) || []).filter(
    (t) => !STOP.has(t) && t.length > 2
  );
}

function detectDelimiter(lines: string[]): string {
  const candidates = [",", "\t", "|", ";"];
  let best = ",";
  let bestScore = -1;
  const sample = lines.slice(0, Math.min(30, lines.length));
  for (const d of candidates) {
    const counts = sample.map(
      (l) => (l.match(new RegExp(d === "|" ? "\\|" : d === "\t" ? "\t" : `\\${d}`, "g")) || []).length
    );
    const nz = counts.filter((c) => c > 0);
    if (nz.length < sample.length * 0.6) continue;
    const avg = nz.reduce((a, b) => a + b, 0) / nz.length;
    const variance =
      nz.reduce((s, c) => s + Math.abs(c - avg), 0) / nz.length;
    const score = avg * 2 - variance;
    if (score > bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

/** Minimal CSV split — handles quoted fields with commas. */
export function splitCsvLine(line: string, delim: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      if (inQ && line[i + 1] === '"') {
        cur += '"';
        i++;
      } else {
        inQ = !inQ;
      }
      continue;
    }
    if (ch === delim && !inQ) {
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out.map((c) => c.trim());
}

export function looksLikeSheet(text: string, name?: string): boolean {
  if (!text || text.length < 20) return false;
  const ext = (name || "").split(".").pop()?.toLowerCase();
  if (ext === "csv" || ext === "tsv" || ext === "tab") return true;
  const lines = text.split("\n").map((l) => l.trimEnd()).filter((l) => l.trim());
  if (lines.length < 3) return false;
  const d = detectDelimiter(lines);
  const cols = splitCsvLine(lines[0], d).length;
  if (cols < 2) return false;
  let ok = 0;
  for (const l of lines.slice(0, 15)) {
    if (Math.abs(splitCsvLine(l, d).length - cols) <= 1) ok++;
  }
  return ok >= Math.min(10, lines.length) * 0.7;
}

function colStats(
  rows: string[][],
  colIdx: number
): { empty: number; unique: number; samples: string[] } {
  const vals = rows.map((r) => (r[colIdx] ?? "").trim());
  const empty = vals.filter((v) => !v).length;
  const set = new Set(vals.filter(Boolean));
  const samples: string[] = [];
  for (const v of set) {
    samples.push(v.length > 40 ? v.slice(0, 37) + "…" : v);
    if (samples.length >= 5) break;
  }
  return { empty, unique: set.size, samples };
}

export function compressSheet(
  source: string,
  opts: SheetCompressOptions
): SheetCompressResult {
  const notes: string[] = [];
  const empty = {
    rows: 0,
    cols: 0,
    sampleRows: 0,
    matchedRows: 0,
    delimiter: ",",
  };
  if (!looksLikeSheet(source, opts.name)) {
    return {
      text: source,
      notes: ["Sheet card skipped (not tabular)"],
      applied: false,
      strategy: "none",
      stats: empty,
    };
  }

  const lines = source
    .split(/\r?\n/)
    .map((l) => l.trimEnd())
    .filter((l) => l.trim());
  const delim = detectDelimiter(lines);
  const header = splitCsvLine(lines[0], delim);
  const maxCols = opts.maxCols ?? 24;
  const colCount = Math.min(header.length, maxCols);
  const dataRows = lines.slice(1).map((l) => splitCsvLine(l, delim));
  const rows = dataRows.length;

  const query = tokenize(opts.prompt || "");
  const matched: string[][] = [];
  if (query.length) {
    for (const r of dataRows) {
      const blob = r.join(" ").toLowerCase();
      let hit = 0;
      for (const q of query) {
        if (blob.includes(q)) hit++;
      }
      if (hit > 0) matched.push(r);
      if (matched.length >= 12) break;
    }
  }

  const maxSample = opts.maxSampleRows ?? 8;
  // stratified: head, mid, tail
  const sampleIdx = new Set<number>();
  if (rows > 0) {
    sampleIdx.add(0);
    sampleIdx.add(Math.floor(rows / 2));
    sampleIdx.add(rows - 1);
    for (let i = 0; sampleIdx.size < maxSample && i < rows; i += Math.max(1, Math.floor(rows / maxSample))) {
      sampleIdx.add(i);
    }
  }
  const sampleRows = [...sampleIdx]
    .sort((a, b) => a - b)
    .slice(0, maxSample)
    .map((i) => dataRows[i]);

  // column profiles
  const profiles: string[] = [];
  for (let c = 0; c < colCount; c++) {
    const name = header[c] || `col${c}`;
    const st = colStats(dataRows, c);
    const emptyPct = rows ? Math.round((st.empty / rows) * 100) : 0;
    const sampleStr = st.samples.length
      ? st.samples.join(" | ")
      : "(empty)";
    profiles.push(
      `- **${name}**: unique=${st.unique}/${rows} empty=${emptyPct}% e.g. ${sampleStr}`
    );
  }
  if (header.length > maxCols) {
    profiles.push(`- … +${header.length - maxCols} more columns omitted`);
  }

  const fmt = (r: string[]) =>
    r
      .slice(0, colCount)
      .map((c) => {
        const v = (c || "").replace(/\s+/g, " ");
        return v.length > 48 ? v.slice(0, 45) + "…" : v;
      })
      .join(" · ");

  const parts: string[] = [];
  parts.push("# SHEET CARD");
  parts.push(
    [
      `File: ${opts.name || "table"}`,
      `Shape: ${rows} data rows × ${header.length} cols`,
      `Delimiter: ${delim === "\t" ? "TAB" : delim}`,
      `Ask: ${(opts.prompt || "").trim().replace(/\s+/g, " ").slice(0, 160) || "(profile)"}`,
      `Fidelity: schema-complete · stats · stratified sample · query hits`,
    ].join("\n")
  );
  parts.push("## Columns\n" + header.slice(0, colCount).map((h) => `\`${h}\``).join(" · "));
  parts.push("## Column profiles\n" + profiles.join("\n"));
  parts.push(
    "## Stratified sample\n" +
      sampleRows.map((r, i) => `${i + 1}. ${fmt(r)}`).join("\n")
  );
  if (matched.length) {
    parts.push(
      `## Query-matched rows (${matched.length}${dataRows.length > matched.length ? "+" : ""})\n` +
        matched.map((r, i) => `${i + 1}. ${fmt(r)}`).join("\n")
    );
  }
  parts.push(
    "## Notes for model\nUse column profiles and samples as ground truth. Do not invent rows. If a calculation needs more rows, say so."
  );

  const brief = parts.join("\n\n").trim();
  if (brief.length >= source.length) {
    return {
      text: source,
      notes: ["Sheet card skipped (table already small)"],
      applied: false,
      strategy: "none",
      stats: {
        rows,
        cols: header.length,
        sampleRows: sampleRows.length,
        matchedRows: matched.length,
        delimiter: delim,
      },
    };
  }

  const saved = Math.round((1 - brief.length / source.length) * 100);
  notes.push(
    `SHEET CARD −${saved}% chars · ${rows}×${header.length} → ${sampleRows.length} sample rows` +
      (matched.length ? ` · ${matched.length} query hits` : "")
  );

  return {
    text: brief,
    notes,
    applied: true,
    strategy: "sheet-card",
    stats: {
      rows,
      cols: header.length,
      sampleRows: sampleRows.length,
      matchedRows: matched.length,
      delimiter: delim,
    },
  };
}
