"use client";

import { useState } from "react";

export function InstallCommand({
  label,
  hint,
  command,
}: {
  label: string;
  hint: string;
  command: string;
}) {
  const [copied, setCopied] = useState(false);

  async function onCopy() {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      /* ignore */
    }
  }

  return (
    <div className="card p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="text-sm font-semibold text-[var(--text)]">{label}</p>
          <p className="text-xs text-[var(--text-dim)]">{hint}</p>
        </div>
        <button
          type="button"
          onClick={() => void onCopy()}
          className="btn btn-secondary !py-1.5 !text-xs"
        >
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <code className="mt-3 block whitespace-pre-wrap break-all rounded-lg border border-[var(--border)] bg-[var(--bg-elevated)] px-3 py-2.5 text-sm leading-relaxed text-[#93b4ff]">
        {command}
      </code>
    </div>
  );
}
