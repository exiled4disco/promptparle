/**
 * Smoke: context fleet fidelity packs for docs, code, sheets, images.
 * Run: npx tsx scripts/smoke-fleet.ts
 */
import { optimizePrompt } from "../src/lib/optimizer";
import { compressCode } from "../src/lib/code-compress";
import { compressSheet } from "../src/lib/sheet-compress";
import { buildImageSignal } from "../src/lib/image-signal";
import { runContextFleet } from "../src/lib/context-fleet";

function pct(a: number, b: number) {
  return b ? Math.round((1 - a / b) * 100) : 0;
}

// --- CODE ---
const code = `
import { readFile } from "fs";
import express from "express";

// lots of noise comment about history of this module
// more noise
// more noise

/**
 * Legacy helper nobody needs to see
 */
function unusedHelper(x: number) {
  return x + 1;
}

export function authenticateUser(token: string, db: any) {
  if (!token) throw new Error("missing token");
  // SECURITY: never log raw tokens
  const user = db.findByToken(token);
  if (!user) throw new Error("unauthorized");
  return user;
}

export class AssetScanner {
  constructor(private apiKey: string) {}

  async scanNetwork(cidr: string) {
    const results = [];
    for (let i = 0; i < 100; i++) {
      results.push({ ip: "10.0.0." + i, open: Math.random() > 0.5 });
    }
    return results.filter((r) => r.open);
  }

  report() {
    return { ok: true, tool: "nmap-compatible" };
  }
}

function formatPretty(data: any) {
  return JSON.stringify(data, null, 2);
}

${Array.from({ length: 40 }, (_, i) => `
function filler${i}(a: number, b: number) {
  const c = a + b;
  const d = c * 2;
  return d - a;
}
`).join("\n")}
`;

const codeR = compressCode(code, {
  prompt: "Review authenticateUser and security of token handling",
  language: "typescript",
  name: "auth.ts",
  profile: "developer",
});
console.log("\n=== CODE ===");
console.log(
  "applied",
  codeR.applied,
  "strategy",
  codeR.strategy,
  "saved%",
  pct(codeR.text.length, code.length),
  codeR.stats
);
console.log(codeR.text.slice(0, 500));
if (!codeR.applied || !/authenticateUser/.test(codeR.text)) {
  console.error("FAIL: code brief missing auth function");
  process.exit(1);
}

// --- SHEET ---
const header = "ip,hostname,zone,criticality,last_seen";
const rows = Array.from({ length: 200 }, (_, i) => {
  const zone = ["OT", "IT", "DMZ"][i % 3];
  const crit = ["high", "med", "low"][i % 3];
  return `10.0.${i % 50}.${i % 200},host-${i},${zone},${crit},2026-0${(i % 9) + 1}-15`;
});
const sheet = [header, ...rows].join("\n");
const sheetR = compressSheet(sheet, {
  prompt: "Which OT assets are high criticality?",
  name: "assets.csv",
});
console.log("\n=== SHEET ===");
console.log(
  "applied",
  sheetR.applied,
  "saved%",
  pct(sheetR.text.length, sheet.length),
  sheetR.stats
);
if (!sheetR.applied || !/criticality/.test(sheetR.text)) {
  console.error("FAIL: sheet card missing columns");
  process.exit(1);
}

// --- MULTI FLEET ---
const multi = [
  "===== FILE: notes.md =====",
  "# Policy",
  "",
  "Operators shall enable MFA.",
  "VPN access is required for remote admin.",
  "",
  "===== FILE: scan.ts =====",
  code,
  "",
  "===== FILE: assets.csv =====",
  sheet,
].join("\n");

const fleet = runContextFleet(multi, {
  prompt: "Security review of policy, auth code, and high OT assets",
  profile: "security-review",
});
console.log("\n=== FLEET ===");
console.log(
  "applied",
  fleet.applied,
  "strategy",
  fleet.strategy,
  "saved%",
  pct(fleet.text.length, multi.length)
);
console.log("notes:", fleet.notes.slice(-3));
if (!fleet.applied) {
  console.error("FAIL: fleet did not apply");
  process.exit(1);
}

// --- IMAGE SIGNAL ---
// minimal 1x1 PNG
const png1x1 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const img = buildImageSignal(
  [{ mediaType: "image/png", dataBase64: png1x1, name: "err.png" }],
  { prompt: "Read the error message in this screenshot", profile: "developer" }
);
console.log("\n=== IMAGE ===");
console.log(img.stats, img.notes[0]);
if (!img.applied || !/error/i.test(img.text)) {
  console.error("FAIL: image signal focus");
  process.exit(1);
}

// --- optimizePrompt end-to-end ---
const opt = optimizePrompt({
  prompt: "Review auth security and OT high assets",
  context: multi,
  profile: "developer",
  images: [{ mediaType: "image/png", dataBase64: png1x1, name: "ui.png" }],
});
console.log("\n=== OPTIMIZE ===");
console.log({
  strategy: opt.strategy,
  original: opt.originalTokens,
  optimized: opt.optimizedTokens,
  reduction: opt.reductionPercent,
  expanded: opt.expanded,
});
console.log(opt.notes.slice(-5));
if (opt.expanded) {
  console.error("FAIL: expanded");
  process.exit(1);
}
if (opt.reductionPercent < 20) {
  console.error("FAIL: expected stronger reduction on multi pack");
  process.exit(1);
}

console.log("\nOK smoke-fleet passed");
