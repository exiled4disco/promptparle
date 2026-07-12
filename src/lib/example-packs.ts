/**
 * Published example packs, illustrative before/after token counts.
 * Not guarantees. Clean prose barely shrinks; noisy packs are where savings show.
 */

export type ExamplePack = {
  id: string;
  title: string;
  scenario: string;
  profile: string;
  dial: number;
  /** Approx input tokens before optimize (illustrative). */
  beforeTokens: number;
  /** Approx tokens after optimize (illustrative). */
  afterTokens: number;
  whyItWorks: string;
  sampleBefore: string;
  sampleAfter: string;
};

export const EXAMPLE_PACKS: ExamplePack[] = [
  {
    id: "noisy-log",
    title: "Noisy OT / app log",
    scenario:
      "A long log dump with timestamps, repeated health checks, stack noise, and one real failure buried in the middle.",
    profile: "log-analysis",
    dial: 4,
    beforeTokens: 18_400,
    afterTokens: 4_120,
    whyItWorks:
      "Logs are full of repeated lines, boilerplate headers, and low-signal chatter. The optimizer keeps the error neighborhood and unique events; it drops redundant heartbeats and duplicate frames.",
    sampleBefore: `[2026-07-11 08:01:02] INFO  sensor=CVIL-A  heartbeat ok latency=12ms
[2026-07-11 08:01:07] INFO  sensor=CVIL-A  heartbeat ok latency=11ms
[2026-07-11 08:01:12] INFO  sensor=CVIL-A  heartbeat ok latency=12ms
… (120 similar heartbeats) …
[2026-07-11 08:14:33] WARN  plc=PLC-7  modbus timeout unit=3 fn=0x03
[2026-07-11 08:14:33] ERROR edge-agent  reconnect attempt 1/5
[2026-07-11 08:14:34] ERROR edge-agent  reconnect attempt 2/5
[2026-07-11 08:14:35] INFO  sensor=CVIL-A  heartbeat ok latency=14ms
… (more heartbeats + full stack traces repeated thrice) …`,
    sampleAfter: `Log focus (dial 4 · log-analysis)
• WARN plc=PLC-7 modbus timeout unit=3 fn=0x03 @ 08:14:33
• ERROR edge-agent reconnect 1/5 then 2/5 immediately after
• Heartbeats: ~120 identical CVIL-A ok lines collapsed (latency ~11-14ms)
• Repeated stack frames deduped; unique frames kept
Ask: root cause and next check on PLC-7 path.`,
  },
  {
    id: "security-review",
    title: "Security review pack",
    scenario:
      "A security pass over multiple files: auth helpers, config, and a long dependency list pasted “just in case.”",
    profile: "security-review",
    dial: 3,
    beforeTokens: 12_600,
    afterTokens: 5_040,
    whyItWorks:
      "Security reviews need auth boundaries, trust edges, and risky APIs, not every import line and license banner. The profile biases toward secrets patterns, auth paths, and network egress; filler docs and duplicate configs compress hard.",
    sampleBefore: `// package-lock excerpt (2k lines)
// LICENSE × 4 copies
// README install notes…
export function verifySession(token: string) {
  // … full 80-line implementation …
}
export function requireAdmin(user: User) { … }
// docker-compose with every service commented twice
// full .env.example with 40 unused keys`,
    sampleAfter: `Security-review pack (dial 3)
Keep:
• verifySession / requireAdmin control flow + failure paths
• Trust boundary: session cookie → API key → provider call
• Egress: provider HTTPS only; desktop tools stay local
• Secret-shaped config keys (masked if present)
Collapsed: lockfile noise, repeated LICENSE/README, duplicate compose comments
Ask: auth bypass, privilege gap, secret leakage in this pack.`,
  },
  {
    id: "clean-prose",
    title: "Clean unique prose",
    scenario:
      "A short, carefully written product question with almost no repetition, already dense.",
    profile: "general",
    dial: 3,
    beforeTokens: 420,
    afterTokens: 410,
    whyItWorks:
      "There is little bloat to remove. Unique prose is already signal. Expect near-zero reduction, and that is correct behavior, not a failure.",
    sampleBefore: `We're evaluating PromptParle for a small security team. We use Claude and Grok with our own keys. Can we keep flagship models while cutting log-heavy context, and does anything store our prompts?`,
    sampleAfter: `We're evaluating PromptParle for a small security team. We use Claude and Grok with our own keys. Can we keep flagship models while cutting log-heavy context, and does anything store our prompts?
(≈ same size, already compact)`,
  },
  {
    id: "attached-user-guide",
    title: "Attached product user guide",
    scenario:
      "Attach a long product user guide and ask for an executive summary. Local prep keeps signal; dial 3 cuts bulk before Grok sees the turn.",
    profile: "executive-summary",
    dial: 3,
    beforeTokens: 100_000,
    afterTokens: 14_000,
    whyItWorks:
      "Long guides carry repeated structure, boilerplate, and low-signal chrome. The desktop client optimizes on the PC, then the model writes the summary. Live UI showed −86% tokens and a downloadable executive summary — one real turn, not a lab mock.",
    sampleBefore: `[ATTACH] Product User Guide (full document)
===== FILE: Product_User_Guide.pdf =====
… hundreds of pages of product UI, procedures, screenshots captions,
repeated section headers, license-ish banners, and operational detail …

User: Provide me an executive summary of the Product User Guide`,
    sampleAfter: `Context after dial 3 local prep (shape):
• [ATTACH] primary this-turn file kept as evidence
• Boilerplate / near-dupes collapsed; hot sections retained
• ~100k → ~14k tokens (−86%) before grok-4.5
Deliverable: Product_User_Guide_Executive_Summary.md
(Real desktop savings line; results vary by document.)`,
  },
];

export function packReduction(pack: ExamplePack): {
  saved: number;
  percent: number;
} {
  const saved = Math.max(0, pack.beforeTokens - pack.afterTokens);
  const percent =
    pack.beforeTokens > 0
      ? Math.round((saved / pack.beforeTokens) * 100)
      : 0;
  return { saved, percent };
}
