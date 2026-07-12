import { Fragment, type ReactNode } from "react";

/**
 * Minimal, dependency-free markdown renderer for TRUSTED repo-owned content
 * (e.g. CHANGELOG.md). Handles headings, lists, code fences, inline code,
 * bold/italic/links, and paragraphs. Does NOT use dangerouslySetInnerHTML —
 * everything is rendered through React elements so text is auto-escaped.
 *
 * Not for untrusted input; it intentionally supports only a safe subset.
 */
function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  // Order: inline code, bold, italic, link. Tokenize with a combined regex.
  const re =
    /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*|_[^_]+_)|(\[[^\]]+\]\([^)]+\))/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) nodes.push(text.slice(last, m.index));
    const tok = m[0];
    const key = `${keyPrefix}-${i++}`;
    if (tok.startsWith("`")) {
      nodes.push(
        <code key={key} className="rounded bg-[var(--bg-elevated,rgba(255,255,255,0.06))] px-1.5 py-0.5 text-[0.85em]">
          {tok.slice(1, -1)}
        </code>
      );
    } else if (tok.startsWith("**")) {
      nodes.push(
        <strong key={key} className="font-semibold">
          {tok.slice(2, -2)}
        </strong>
      );
    } else if (tok.startsWith("[")) {
      const linkMatch = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(tok);
      if (linkMatch) {
        nodes.push(
          <a
            key={key}
            href={linkMatch[2]}
            className="text-[var(--accent-strong)] underline underline-offset-2"
          >
            {linkMatch[1]}
          </a>
        );
      } else {
        nodes.push(tok);
      }
    } else {
      // italic (* or _)
      nodes.push(
        <em key={key} className="italic">
          {tok.slice(1, -1)}
        </em>
      );
    }
    last = m.index + tok.length;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}

export function Markdown({ source }: { source: string }) {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const blocks: ReactNode[] = [];
  let i = 0;
  let key = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block
    if (line.trimStart().startsWith("```")) {
      const buf: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trimStart().startsWith("```")) {
        buf.push(lines[i]);
        i++;
      }
      i++; // closing fence
      blocks.push(
        <pre
          key={key++}
          className="overflow-x-auto rounded-lg border border-[var(--border)] bg-[rgba(0,0,0,0.35)] p-4 text-sm"
        >
          <code>{buf.join("\n")}</code>
        </pre>
      );
      continue;
    }

    // Headings
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      const level = h[1].length;
      const content = renderInline(h[2], `h${key}`);
      const cls =
        level === 1
          ? "mt-2 text-2xl font-bold"
          : level === 2
            ? "mt-8 border-b border-[var(--border)] pb-2 text-xl font-semibold"
            : "mt-6 text-lg font-semibold";
      const Tag = (`h${Math.min(level, 6)}` as unknown) as keyof React.JSX.IntrinsicElements;
      blocks.push(
        <Tag key={key++} className={cls}>
          {content}
        </Tag>
      );
      i++;
      continue;
    }

    // List block (unordered or ordered)
    if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
      const items: ReactNode[] = [];
      const ordered = /^\s*\d+\.\s+/.test(line);
      while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
        const item = lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, "");
        items.push(
          <li key={items.length}>{renderInline(item, `li${key}-${items.length}`)}</li>
        );
        i++;
      }
      blocks.push(
        ordered ? (
          <ol key={key++} className="ml-5 grid list-decimal gap-1">
            {items}
          </ol>
        ) : (
          <ul key={key++} className="ml-5 grid list-disc gap-1">
            {items}
          </ul>
        )
      );
      continue;
    }

    // Blank line
    if (line.trim() === "") {
      i++;
      continue;
    }

    // Horizontal rule
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {
      blocks.push(<hr key={key++} className="my-6 border-[var(--border)]" />);
      i++;
      continue;
    }

    // Paragraph (gather until blank/structural)
    const para: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      !/^(#{1,6})\s/.test(lines[i]) &&
      !/^\s*([-*+]|\d+\.)\s+/.test(lines[i]) &&
      !lines[i].trimStart().startsWith("```")
    ) {
      para.push(lines[i]);
      i++;
    }
    blocks.push(
      <p key={key++} className="text-[var(--text-muted)]">
        {renderInline(para.join(" "), `p${key}`)}
      </p>
    );
  }

  return (
    <div className="grid gap-3 leading-relaxed">
      {blocks.map((b, idx) => (
        <Fragment key={idx}>{b}</Fragment>
      ))}
    </div>
  );
}
