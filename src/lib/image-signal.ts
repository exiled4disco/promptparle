/**
 * IMAGE SIGNAL: high-fidelity vision steering without bloating text tokens.
 *
 * Binary images still go to the provider (multimodal). We add a tight focus
 * brief so the model knows what to extract, and we can describe dimensions
 * from headers without decoding the full bitmap.
 */

import type { AdapterImage } from "./adapters/types";

export type ImageSignalOptions = {
  prompt: string;
  profile?: string;
};

export type ImageMeta = {
  name?: string;
  mediaType: string;
  bytesApprox: number;
  width?: number;
  height?: number;
  format: string;
};

export type ImageSignalResult = {
  text: string;
  notes: string[];
  applied: boolean;
  strategy: string;
  stats: {
    images: number;
    withDimensions: number;
    totalBytesApprox: number;
  };
};

function b64ByteLen(b64: string): number {
  const s = b64.replace(/\s/g, "");
  const padding = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((s.length * 3) / 4) - padding);
}

/** Decode enough base64 to read image headers (sync, no deps). */
function headerBytes(b64: string, n = 64): Uint8Array {
  const clean = b64.replace(/\s/g, "");
  // 4 base64 chars → 3 bytes; need ~ceil(n/3)*4 chars
  const chars = Math.min(clean.length, Math.ceil(n / 3) * 4 + 4);
  const slice = clean.slice(0, chars);
  try {
    const bin = Buffer.from(slice, "base64");
    return new Uint8Array(bin.buffer, bin.byteOffset, bin.byteLength);
  } catch {
    return new Uint8Array(0);
  }
}

function u16be(b: Uint8Array, i: number): number {
  return (b[i] << 8) | b[i + 1];
}
function u32be(b: Uint8Array, i: number): number {
  return (
    ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0
  );
}
function u16le(b: Uint8Array, i: number): number {
  return b[i] | (b[i + 1] << 8);
}

export function readImageDimensions(
  mediaType: string,
  dataBase64: string
): { width?: number; height?: number; format: string } {
  const b = headerBytes(dataBase64, 96);
  if (b.length < 10) return { format: mediaType };

  // PNG
  if (
    b[0] === 0x89 &&
    b[1] === 0x50 &&
    b[2] === 0x4e &&
    b[3] === 0x47 &&
    b.length >= 24
  ) {
    return {
      format: "png",
      width: u32be(b, 16),
      height: u32be(b, 20),
    };
  }

  // GIF
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b.length >= 10) {
    return {
      format: "gif",
      width: u16le(b, 6),
      height: u16le(b, 8),
    };
  }

  // JPEG: scan for SOF0/2
  if (b[0] === 0xff && b[1] === 0xd8) {
    // need more bytes for JPEG
    const full = headerBytes(dataBase64, 512);
    let i = 2;
    while (i < full.length - 9) {
      if (full[i] !== 0xff) {
        i++;
        continue;
      }
      const marker = full[i + 1];
      if (marker === 0xd8 || marker === 0xd9) {
        i += 2;
        continue;
      }
      const len = u16be(full, i + 2);
      // SOF0, SOF1, SOF2
      if (
        marker === 0xc0 ||
        marker === 0xc1 ||
        marker === 0xc2
      ) {
        return {
          format: "jpeg",
          height: u16be(full, i + 5),
          width: u16be(full, i + 7),
        };
      }
      i += 2 + len;
    }
    return { format: "jpeg" };
  }

  // WEBP RIFF
  if (
    b[0] === 0x52 &&
    b[1] === 0x49 &&
    b[2] === 0x46 &&
    b[3] === 0x46 &&
    b.length >= 30
  ) {
    // VP8X
    if (b[12] === 0x56 && b[13] === 0x50 && b[14] === 0x38 && b[15] === 0x58) {
      const w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
      const h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
      return { format: "webp", width: w, height: h };
    }
    // VP8 lossy
    if (b[12] === 0x56 && b[13] === 0x50 && b[14] === 0x38 && b[15] === 0x20) {
      // more complex: skip
      return { format: "webp" };
    }
    return { format: "webp" };
  }

  return { format: mediaType.replace(/^image\//, "") || "image" };
}

export function inspectImage(img: AdapterImage): ImageMeta {
  const dim = readImageDimensions(img.mediaType, img.dataBase64);
  return {
    name: img.name,
    mediaType: img.mediaType,
    bytesApprox: b64ByteLen(img.dataBase64),
    width: dim.width,
    height: dim.height,
    format: dim.format,
  };
}

/** Focus keywords from the user ask: steers vision without extra image tokens. */
function focusFromPrompt(prompt: string): string[] {
  const p = (prompt || "").toLowerCase();
  const foci: string[] = [];
  const rules: [RegExp, string][] = [
    [/\b(error|exception|stack|traceback|fail)/, "errors / stack traces"],
    [/\b(table|grid|spreadsheet|column|row)/, "tables / grid values"],
    [/\b(chart|graph|plot|axis)/, "chart labels and values"],
    [/\b(ui|button|menu|dialog|screenshot|screen)/, "UI labels and layout"],
    [/\b(code|function|class|snippet|ide)/, "visible code text"],
    [/\b(ip|port|firewall|rule|log)/, "IPs, ports, security indicators"],
    [/\b(logo|brand|color|design)/, "visual design / branding"],
    [/\b(ocr|text|read|transcribe|extract)/, "all readable text"],
    [/\b(diagram|architecture|flow)/, "boxes, arrows, relationships"],
    [/\b(diff|before|after|compare)/, "differences between regions"],
  ];
  for (const [re, label] of rules) {
    if (re.test(p)) foci.push(label);
  }
  if (!foci.length) {
    foci.push("all readable text");
    foci.push("layout structure");
    foci.push("anomalies / highlighted items");
  }
  return [...new Set(foci)].slice(0, 6);
}

/**
 * Build a short IMAGE SIGNAL brief for the text channel.
 * Binary images are still forwarded separately by run-prompt.
 */
export function buildImageSignal(
  images: AdapterImage[] | undefined,
  opts: ImageSignalOptions
): ImageSignalResult {
  const list = images || [];
  if (!list.length) {
    return {
      text: "",
      notes: [],
      applied: false,
      strategy: "none",
      stats: { images: 0, withDimensions: 0, totalBytesApprox: 0 },
    };
  }

  const metas = list.map(inspectImage);
  const focus = focusFromPrompt(opts.prompt);
  let withDimensions = 0;
  let totalBytes = 0;

  const lines: string[] = [
    "# IMAGE SIGNAL",
    [
      `Images attached: ${metas.length} (binary → vision API, not text-tokenized)`,
      `Ask: ${(opts.prompt || "").trim().replace(/\s+/g, " ").slice(0, 160) || "(general)"}`,
      `Profile: ${opts.profile || "general"}`,
      `Fidelity: full pixels to model · text brief steers extraction`,
    ].join("\n"),
    "## Focus (extract first)\n" + focus.map((f) => `- ${f}`).join("\n"),
    "## Attachments",
  ];

  metas.forEach((m, i) => {
    totalBytes += m.bytesApprox;
    const dim =
      m.width && m.height
        ? `${m.width}×${m.height}px`
        : "dimensions unknown";
    if (m.width && m.height) withDimensions++;
    const kb = Math.max(1, Math.round(m.bytesApprox / 1024));
    lines.push(
      `${i + 1}. **${m.name || `image-${i + 1}`}**: ${m.format} · ${dim} · ~${kb}KB`
    );
  });

  lines.push(
    "## Instructions for model\n" +
      [
        "- Treat attached images as primary evidence for visual facts.",
        "- Prefer OCR of labels, numbers, errors over vague description.",
        "- If text is unreadable, say so; do not invent values.",
        "- Cross-check image facts against any CODE/SHEET/SIGNAL briefs in context.",
      ].join("\n")
  );

  const text = lines.join("\n\n");
  return {
    text,
    notes: [
      `IMAGE SIGNAL: ${metas.length} image(s) · vision full-fidelity · text focus brief ~${text.length} chars`,
    ],
    applied: true,
    strategy: "image-signal",
    stats: {
      images: metas.length,
      withDimensions,
      totalBytesApprox: totalBytes,
    },
  };
}

/**
 * If someone pasted a giant data-URL into context text, replace with a card
 * (binary should use the images[] channel).
 */
export function stripInlineDataUrls(context: string): {
  text: string;
  notes: string[];
  removed: number;
} {
  const notes: string[] = [];
  let removed = 0;
  const text = context.replace(
    /data:(image\/[a-z0-9.+-]+);base64,([A-Za-z0-9+/=\s]{200,})/gi,
    (_m, mime: string, b64: string) => {
      removed++;
      const dim = readImageDimensions(mime, b64.replace(/\s/g, ""));
      const kb = Math.max(1, Math.round(b64ByteLen(b64) / 1024));
      const dimS =
        dim.width && dim.height ? `${dim.width}×${dim.height}` : "?×?";
      return `[INLINE IMAGE removed from text context; re-attach as vision image: ${mime} ${dimS} ~${kb}KB]`;
    }
  );
  if (removed) {
    notes.push(
      `Moved ${removed} inline data-URL image(s) out of text (use attach/paste for vision)`
    );
  }
  return { text, notes, removed };
}
