"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import type { SessionUser } from "@/lib/auth";
import { RETENTION_OPTIONS } from "@/lib/constants";
import { getPlanLimits } from "@/lib/plans";

type ActiveClient = {
  clientId: string;
  hostname: string | null;
  platform: string | null;
  appVersion: string | null;
  lastSeenAt: string | Date;
};

export function SettingsForm({
  user,
  activeClients = [],
}: {
  user: SessionUser;
  activeClients?: ActiveClient[];
}) {
  const router = useRouter();
  const limits = getPlanLimits(user.plan);
  const [name, setName] = useState(user.name || "");
  const [retentionPolicy, setRetentionPolicy] = useState(user.retentionPolicy);
  const [storePrompts, setStorePrompts] = useState(user.storePrompts);
  const [featProjectPc, setFeatProjectPc] = useState(user.featProjectPc !== false);
  const [featProjectSsh, setFeatProjectSsh] = useState(
    user.featProjectSsh !== false
  );
  const [featProjectGit, setFeatProjectGit] = useState(
    user.featProjectGit !== false
  );
  const [allowedIps, setAllowedIps] = useState(user.allowedIps || "");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    setLoading(true);
    try {
      const res = await fetch("/api/settings", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name,
          retentionPolicy,
          storePrompts: retentionPolicy === "none" ? false : storePrompts,
          featProjectPc,
          featProjectSsh,
          featProjectGit,
          allowedIps,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to save");
        return;
      }
      setSuccess("Saved.");
      router.refresh();
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="card grid gap-3 p-4 sm:p-5">
      {error && <div className="alert alert-error py-2 text-sm">{error}</div>}
      {success && (
        <div className="alert alert-success py-2 text-sm">{success}</div>
      )}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <div className="field !mb-0">
          <label className="label !mb-1 text-xs">Email</label>
          <input className="input !py-2 text-sm" value={user.email} disabled />
        </div>
        <div className="field !mb-0">
          <label className="label !mb-1 text-xs" htmlFor="name">
            Display name
          </label>
          <input
            id="name"
            className="input !py-2 text-sm"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Your name"
          />
        </div>
        <div className="field !mb-0">
          <label className="label !mb-1 text-xs" htmlFor="retention">
            Prompt retention
          </label>
          <select
            id="retention"
            className="select !py-2 text-sm"
            value={retentionPolicy}
            onChange={(e) => setRetentionPolicy(e.target.value)}
          >
            {RETENTION_OPTIONS.map((opt) => (
              <option key={opt.id} value={opt.id}>
                {opt.label}
              </option>
            ))}
          </select>
        </div>
      </div>

      <label className="flex items-center gap-2 rounded-lg border border-[var(--border)] px-3 py-2 text-sm">
        <input
          type="checkbox"
          checked={storePrompts && retentionPolicy !== "none"}
          disabled={retentionPolicy === "none"}
          onChange={(e) => setStorePrompts(e.target.checked)}
        />
        <span>
          <span className="font-medium">Store before/after prompt text</span>
          <span className="ml-1 text-[var(--text-muted)]">
            (plan-capped · secrets masked)
          </span>
        </span>
      </label>

      <div className="rounded-lg border border-[var(--border)] px-3 py-2.5">
        <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-sm font-semibold">Desktop project connections</h2>
          <span className="text-xs text-[var(--text-muted)]">
            Applies on next client heartbeat
          </span>
        </div>
        <div className="grid gap-1.5 sm:grid-cols-3">
          <label className="flex items-center gap-2 rounded-md px-1.5 py-1.5 text-sm hover:bg-[var(--bg-soft)]">
            <input
              type="checkbox"
              checked={featProjectPc}
              onChange={(e) => setFeatProjectPc(e.target.checked)}
            />
            <span className="font-medium">This PC folder</span>
          </label>
          <label className="flex items-center gap-2 rounded-md px-1.5 py-1.5 text-sm hover:bg-[var(--bg-soft)]">
            <input
              type="checkbox"
              checked={featProjectSsh}
              onChange={(e) => setFeatProjectSsh(e.target.checked)}
            />
            <span className="font-medium">SSH</span>
          </label>
          <label className="flex items-center gap-2 rounded-md px-1.5 py-1.5 text-sm hover:bg-[var(--bg-soft)]">
            <input
              type="checkbox"
              checked={featProjectGit}
              onChange={(e) => setFeatProjectGit(e.target.checked)}
            />
            <span className="font-medium">Git / GitHub</span>
          </label>
        </div>
      </div>

      <div className="rounded-lg border border-[var(--border)] px-3 py-2.5">
        <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-sm font-semibold">API IP allowlist</h2>
          <span className="text-xs text-[var(--text-muted)]">
            Desktop API keys only · empty = any IP
          </span>
        </div>
        <div className="field !mb-0">
          <label className="label !mb-1 text-xs" htmlFor="allowedIps">
            Allowed IPv4 / CIDR (one per line)
          </label>
          <textarea
            id="allowedIps"
            className="input !py-2 font-mono text-xs"
            rows={3}
            value={allowedIps}
            onChange={(e) => setAllowedIps(e.target.value)}
            placeholder={"203.0.113.10\n198.51.100.0/24"}
            spellCheck={false}
          />
          <p className="mt-1.5 text-[11px] leading-snug text-[var(--text-muted)]">
            When set, only listed addresses may call{" "}
            <code className="text-[10px]">/api/v1/*</code> with your API key.
            Portal login and Settings stay open so you can fix mistakes. Max 32
            entries.
          </p>
        </div>
      </div>

      <div className="rounded-lg border border-[var(--border)] px-3 py-2.5">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-sm font-semibold">Desktop seats</h2>
          <span className="text-xs text-[var(--text-muted)]">
            <span className="capitalize">{user.plan}</span>
            {" · "}
            {activeClients.length}/{limits.maxDesktopClients} active
            {limits.id === "free" ? " (Free = 1)" : ""}
            {" · frees ~2m idle"}
          </span>
        </div>
        {activeClients.length > 0 && (
          <ul className="mt-2 flex flex-wrap gap-1.5">
            {activeClients.map((c) => (
              <li
                key={c.clientId}
                className="rounded-md border border-[var(--border)] px-2 py-1 text-xs"
                title={c.clientId}
              >
                <span className="font-medium">{c.hostname || "Desktop"}</span>
                <span className="text-[var(--text-muted)]">
                  {" "}
                  · {c.platform || "?"}
                  {c.appVersion ? ` · v${c.appVersion}` : ""}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2 border-t border-[var(--border)] pt-3">
        <p className="max-w-xl text-[11px] leading-snug text-[var(--text-muted)]">
          Keys encrypted at rest · desktop secrets stay on your PC · SSH/git
          credentials never uploaded · revoke keys anytime
        </p>
        <button
          type="submit"
          className="btn btn-primary shrink-0 !px-4 !py-2 text-sm"
          disabled={loading}
        >
          {loading ? "Saving…" : "Save settings"}
        </button>
      </div>
    </form>
  );
}
