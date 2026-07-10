import { optimizePrompt } from "../src/lib/optimizer";

const section = `# Automated Moving Target Defense

## 1. The Reconnaissance Problem
Attackers fingerprint networks slowly. Static surfaces make maps durable.
**AMTD breaks it.** A network whose attack surface continuously changes cannot be reliably fingerprinted.

## 2. What AMTD Is
AMTD is not deception alone. AMTD is continuous change of attack surface with attribution.

### AMTD vs Deception
Deception plants fake assets. AMTD rotates real-looking personas at scale.

## 3. The Five Operating Principles
### Principle 1 — The Attempt Matters
Every probe is logged. Shall enforce surgical response.

### Principle 2 — Surgical, Not Broad
Must not block entire subnets when one host is hostile.

### Principle 3 — Start Open, Narrow In
Required to begin permissive then tighten.

### Principle 4 — Sensors Are Mini-Orchestrators
Sensors must coordinate decoy responses.

### Principle 5 — Hive
Hundreds rotating, not static. Hive defenses cannot be mapped.

## 4. How ExampleCorp Delivers AMTD
### 4.1 Sensor Subsystem
Sensors observe and act with full context.
### 4.2 Decoy Responder
Personas answer probes across 120 protocols.
### 4.3 Rotation Engine
Rotates every 15 minutes by default.
### 4.4 ACE Lever
ACE levers control aggressiveness levels 1 through 5 for enforcement.
`;

const doc = section.repeat(4);
const prompt = "Review the attached material and give the most useful findings first.";

for (const level of [1, 2, 3, 4, 5] as const) {
  const r = optimizePrompt({
    prompt,
    context: "===== FILE: AMTD-Doctrine.md =====\n" + doc,
    profile: "general",
    compressionLevel: level,
  });
  console.log(
    `dial ${level}: ${r.originalTokens} → ${r.optimizedTokens} (−${r.reductionPercent}%) strategy=${r.strategy}`
  );
}
