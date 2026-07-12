"use client";

import { FormEvent, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { SessionUser } from "@/lib/auth";
import { PROVIDERS, RETENTION_OPTIONS } from "@/lib/constants";
import { getPlanLimits } from "@/lib/plans";

type ActiveClient = {
  clientId: string;
  hostname: string | null;
  platform: string | null;
  appVersion: string | null;
  lastSeenAt: string | Date;
};

type ModelOption = {
  id: string;
  label: string;
  source?: string;
};

function parsePreferredModels(
  raw: string | Record<string, string> | null | undefined
): Record<string, string> {
  if (!raw) return {};
  if (typeof raw === "object") return { ...raw };
  try {
    const o = JSON.parse(raw) as unknown;
    if (!o || typeof o !== "object") return {};
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(o as Record<string, unknown>)) {
      if (typeof v === "string" && v.trim()) out[k] = v.trim();
    }
    return out;
  } catch {
    return {};
  }
}

export function SettingsForm({
  user,
  activeClients = [],
  modelCatalog: initialCatalog = {},
}: {
  user: SessionUser;
  activeClients?: ActiveClient[];
  modelCatalog?: Record<string, ModelOption[]>;
}) {
  const router = useRouter();
  const limits = getPlanLimits(user.plan);
  const [name, setName] = useState(user.name || "");
  const [retentionPolicy, setRetentionPolicy] = useState(user.retentionPolicy);
  const [featProjectPc, setFeatProjectPc] = useState(user.featProjectPc !== false);
  const [featProjectSsh, setFeatProjectSsh] = useState(
    user.featProjectSsh !== false
  );
  const [featProjectGit, setFeatProjectGit] = useState(
    user.featProjectGit !== false
  );
  const [allowedIps, setAllowedIps] = useState(user.allowedIps || "");
  const [preferredProvider, setPreferredProvider] = useState(
    user.preferredProvider || ""
  );
  const [preferredModels, setPreferredModels] = useState<Record<string, string>>(
    () => parsePreferredModels(user.preferredModels)
  );
  const [defaultDial, setDefaultDial] = useState(user.defaultDial ?? 3);
  const [defaultToolsEnabled, setDefaultToolsEnabled] = useState(
    user.defaultToolsEnabled !== false
  );
  const modelCatalog = initialCatalog;
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const enabledProviders = useMemo(
    () =>
      PROVIDERS.filter((p) => p.enabled).map((p) => ({
        id: p.id as string,
        name: p.name,
        defaultModel: p.defaultModel,
      })),
    []
  );

  function setModelForProvider(providerId: string, model: string) {
    setPreferredModels((prev) => {
      const next = { ...prev };
      if (!model.trim()) delete next[providerId];
      else next[providerId] = model.trim();
      return next;
    });
  }

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
          // Product policy: stats + session titles only, never store prompt/context text
          storePrompts: false,
          featProjectPc,
          featProjectSsh,
          featProjectGit,
          allowedIps,
          preferredProvider: preferredProvider || null,
          preferredModels,
          defaultDial,
          defaultToolsEnabled,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to save");
        return;
      }
      setSuccess("Saved. Desktop clients pick this up on next heartbeat (~1 min).");
      router.refresh();
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  const dialLabels: Record<number, string> = {
    1: "1 · Max fidelity",
    2: "2 · Light",
    3: "3 · Balanced",
    4: "4 · Aggressive",
    5: "5 · Max savings",
  };

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
            Usage history retention
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

      <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-soft)] px-3 py-2.5 text-sm text-[var(--text-muted)]">
        <span className="font-medium text-[var(--text)]">Usage privacy</span>
        <span className="ml-1">
          We store token stats and session titles only. Prompt text and context
          are never captured or stored in the cloud (portal or desktop).
        </span>
      </div>

      <div className="rounded-lg border border-[var(--border)] px-3 py-2.5">
        <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-sm font-semibold">Chat defaults (portal ↔ desktop)</h2>
          <span className="text-xs text-[var(--text-muted)]">
            Syncs to client on install / heartbeat
          </span>
        </div>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div className="field !mb-0">
            <label className="label !mb-1 text-xs" htmlFor="preferredProvider">
              Preferred provider
            </label>
            <select
              id="preferredProvider"
              className="select !py-2 text-sm"
              value={preferredProvider}
              onChange={(e) => setPreferredProvider(e.target.value)}
            >
              <option value="">Auto (first configured)</option>
              {enabledProviders.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </div>
          <div className="field !mb-0">
            <label className="label !mb-1 text-xs" htmlFor="defaultDial">
              Default dial
            </label>
            <select
              id="defaultDial"
              className="select !py-2 text-sm"
              value={defaultDial}
              onChange={(e) => setDefaultDial(Number(e.target.value))}
            >
              {[1, 2, 3, 4, 5].map((n) => (
                <option key={n} value={n}>
                  {dialLabels[n]}
                </option>
              ))}
            </select>
          </div>
          <div className="field !mb-0 flex items-end">
            <label className="flex w-full items-center gap-2 rounded-md border border-[var(--border)] px-3 py-2 text-sm">
              <input
                type="checkbox"
                checked={defaultToolsEnabled}
                onChange={(e) => setDefaultToolsEnabled(e.target.checked)}
              />
              <span className="font-medium">Tools on by default</span>
            </label>
          </div>
        </div>

        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          {enabledProviders.map((p) => {
            const catalog = modelCatalog[p.id] || [
              { id: p.defaultModel, label: p.defaultModel },
            ];
            const current = preferredModels[p.id] || p.defaultModel;
            const inList = catalog.some((m) => m.id === current);
            const selectValue = inList ? current : "__custom__";
            return (
              <div key={p.id} className="field !mb-0">
                <label className="label !mb-1 text-xs" htmlFor={`model-${p.id}`}>
                  {p.name} model
                  <span className="ml-1 font-normal text-[var(--text-muted)]">
                    ({catalog.length} listed)
                  </span>
                </label>
                <select
                  id={`model-${p.id}`}
                  className="select !py-2 font-mono text-xs"
                  value={selectValue}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (v === "__custom__") {
                      // keep current custom; focus sibling input via state
                      if (!inList && current) return;
                      setModelForProvider(p.id, current || p.defaultModel);
                      return;
                    }
                    setModelForProvider(p.id, v);
                  }}
                >
                  {catalog.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.label} ({m.id})
                    </option>
                  ))}
                  <option value="__custom__">Custom model id…</option>
                </select>
                {(selectValue === "__custom__" || !inList) && (
                  <input
                    className="input mt-1.5 !py-2 font-mono text-xs"
                    value={current}
                    onChange={(e) => setModelForProvider(p.id, e.target.value)}
                    placeholder={p.defaultModel}
                    spellCheck={false}
                    aria-label={`${p.name} custom model id`}
                  />
                )}
                <p className="mt-1 text-[11px] text-[var(--text-muted)]">
                  Only {p.name} models. Desktop refreshes live lists from your
                  API key when available.
                </p>
              </div>
            );
          })}
        </div>
      </div>

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
          credentials never uploaded · revoke keys anytime · model prefs sync both
          ways with the desktop client
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
