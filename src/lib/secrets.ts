/**
 * Lightweight secret detection + masking on the gateway before the provider call.
 * Desktop client may also mask earlier; this is the server-side second layer.
 * Conservative patterns: prefer false positives over leaking keys to the model.
 */

const PATTERNS: { name: string; re: RegExp; replace: string }[] = [
  {
    name: "openai_key",
    re: /\bsk-(?!ant-)[A-Za-z0-9_-]{20,}\b/g,
    replace: "[REDACTED_OPENAI_KEY]",
  },
  {
    name: "anthropic_key",
    re: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g,
    replace: "[REDACTED_ANTHROPIC_KEY]",
  },
  {
    name: "gemini_key",
    re: /\bAIza[0-9A-Za-z_-]{20,}\b/g,
    replace: "[REDACTED_GEMINI_KEY]",
  },
  {
    name: "xai_key",
    re: /\bxai-[A-Za-z0-9_-]{20,}\b/g,
    replace: "[REDACTED_XAI_KEY]",
  },
  {
    name: "aws_key",
    re: /\bAKIA[0-9A-Z]{16}\b/g,
    replace: "[REDACTED_AWS_KEY_ID]",
  },
  {
    name: "aws_secret",
    re: /(?:aws_secret_access_key|AWS_SECRET_ACCESS_KEY)\s*[=:]\s*['"]?([A-Za-z0-9/+=]{30,})['"]?/gi,
    replace: "AWS_SECRET_ACCESS_KEY=[REDACTED_AWS_SECRET]",
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
    name: "github_oauth",
    re: /\bgho_[A-Za-z0-9]{20,}\b/g,
    replace: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    name: "github_app",
    re: /\b(ghu|ghs)_[A-Za-z0-9]{20,}\b/g,
    replace: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    name: "slack_token",
    re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g,
    replace: "[REDACTED_SLACK_TOKEN]",
  },
  {
    name: "stripe_key",
    re: /\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]{16,}\b/g,
    replace: "[REDACTED_STRIPE_KEY]",
  },
  {
    name: "azure_conn",
    re: /(?:DefaultEndpointsProtocol|AccountKey)=[^\s;]{8,}/gi,
    replace: "[REDACTED_AZURE_CONNECTION]",
  },
  {
    name: "connection_string",
    re: /\b(?:mongodb(?:\+srv)?|postgres(?:ql)?|mysql|redis|amqp):\/\/[^\s'"]+/gi,
    replace: "[REDACTED_CONNECTION_STRING]",
  },
  {
    name: "private_key",
    re: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/g,
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
  {
    name: "password_assignment",
    re: /(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token)\s*[=:]\s*['"]?[^\s'"]{8,}['"]?/gi,
    replace: "[REDACTED_CREDENTIAL_ASSIGNMENT]",
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
