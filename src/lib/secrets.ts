/**
 * Lightweight secret detection + masking before prompts leave PromptParle.
 * Conservative patterns — prefer false positives over leaking keys.
 */

const PATTERNS: { name: string; re: RegExp; replace: string }[] = [
  {
    name: "openai_key",
    re: /\bsk-[A-Za-z0-9_-]{20,}\b/g,
    replace: "[REDACTED_OPENAI_KEY]",
  },
  {
    name: "anthropic_key",
    re: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g,
    replace: "[REDACTED_ANTHROPIC_KEY]",
  },
  {
    name: "aws_key",
    re: /\bAKIA[0-9A-Z]{16}\b/g,
    replace: "[REDACTED_AWS_KEY_ID]",
  },
  {
    name: "github_pat",
    re: /\bghp_[A-Za-z0-9]{20,}\b/g,
    replace: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    name: "github_fine",
    re: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
    replace: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    name: "slack_token",
    re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g,
    replace: "[REDACTED_SLACK_TOKEN]",
  },
  {
    name: "private_key",
    re: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g,
    replace: "[REDACTED_PRIVATE_KEY]",
  },
  {
    name: "jwt",
    re: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g,
    replace: "[REDACTED_JWT]",
  },
  {
    name: "pp_live",
    re: /\bpp_live_[a-f0-9]{20,}\b/gi,
    replace: "[REDACTED_PROMPTPARLE_KEY]",
  },
  {
    name: "generic_bearer",
    re: /\bBearer\s+[A-Za-z0-9._\-+/=]{20,}\b/gi,
    replace: "Bearer [REDACTED_TOKEN]",
  },
];

export type SecretScanResult = {
  text: string;
  masked: boolean;
  findings: string[];
};

export function maskSecrets(input: string): SecretScanResult {
  let text = input;
  const findings: string[] = [];

  for (const p of PATTERNS) {
    if (p.re.test(text)) {
      findings.push(p.name);
      // reset lastIndex for global regex reuse
      p.re.lastIndex = 0;
      text = text.replace(p.re, p.replace);
      p.re.lastIndex = 0;
    } else {
      p.re.lastIndex = 0;
    }
  }

  return {
    text,
    masked: findings.length > 0,
    findings: [...new Set(findings)],
  };
}
