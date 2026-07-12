"use client";

import { useRouter } from "next/navigation";
import Link from "next/link";
import { useState } from "react";
import { SUPPORT } from "@/lib/pricing";

type OS = "windows" | "linux";

const APP_URL = "https://promptparle.com";
const INSTALL = {
  windows: `irm ${APP_URL}/install.ps1 | iex`,
  linux: `curl -fsSL ${APP_URL}/install.sh | bash`,
};

function CopyField({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="grid gap-1">
      <div className="text-xs font-medium text-[var(--text-dim)]">{label}</div>
      <div className="flex items-stretch gap-2">
        <code className="min-w-0 flex-1 overflow-x-auto rounded-lg border border-[var(--border)] bg-[rgba(0,0,0,0.35)] px-3 py-2.5 font-mono text-sm">
          {value}
        </code>
        <button
          type="button"
          className="btn btn-secondary shrink-0 !px-3 text-sm"
          onClick={async () => {
            try {
              await navigator.clipboard.writeText(value);
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            } catch {
              /* clipboard blocked — user can select manually */
            }
          }}
        >
          {copied ? "Copied ✓" : "Copy"}
        </button>
      </div>
    </div>
  );
}

export function WelcomeWizard({ userName }: { userName: string | null }) {
  const router = useRouter();
  const [step, setStep] = useState(1);
  const [os, setOs] = useState<OS>("windows");
  const [keyName, setKeyName] = useState("");
  const [fullKey, setFullKey] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const totalSteps = 5;
  const osLabel = os === "windows" ? "Windows" : "Linux / macOS";
  const installCmd = INSTALL[os];

  async function finish() {
    // best-effort mark; never block leaving
    try {
      await fetch("/api/onboarding", { method: "POST" });
    } catch {
      /* ignore */
    }
    router.push("/app");
    router.refresh();
  }

  async function createKey() {
    setError(null);
    setCreating(true);
    try {
      const name =
        keyName.trim() ||
        `${os === "windows" ? "Windows" : "Linux"} desktop`;
      const res = await fetch("/api/api-keys", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not create the key.");
        return;
      }
      setFullKey(data.fullKey);
      setStep(4);
    } catch {
      setError("Network error. Try again.");
    } finally {
      setCreating(false);
    }
  }

  return (
    <div className="mx-auto grid w-full max-w-2xl gap-6">
      {/* progress */}
      <div className="flex items-center gap-2">
        {Array.from({ length: totalSteps }).map((_, i) => (
          <div
            key={i}
            className={
              "h-1.5 flex-1 rounded-full " +
              (i < step ? "bg-[var(--accent)]" : "bg-[var(--border)]")
            }
          />
        ))}
      </div>

      <div className="card grid gap-5 p-6 sm:p-8">
        {/* STEP 1 — welcome + OS */}
        {step === 1 && (
          <>
            <div className="grid gap-2">
              <h1 className="page-title !mb-0">
                Welcome{userName ? `, ${userName}` : ""} — thank you!
              </h1>
              <p className="page-sub !mx-0 !mt-0">
                Let&apos;s walk through the parts that matter to get PromptParle
                installed. It takes about two minutes.
              </p>
            </div>
            <div className="grid gap-2">
              <div className="text-sm font-medium">Which desktop are you installing on?</div>
              <div className="grid gap-2 sm:grid-cols-2">
                {(["windows", "linux"] as OS[]).map((o) => (
                  <button
                    key={o}
                    type="button"
                    onClick={() => setOs(o)}
                    className={
                      "rounded-lg border px-4 py-3 text-left text-sm " +
                      (os === o
                        ? "border-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent-strong)]"
                        : "border-[var(--border)] hover:bg-white/5")
                    }
                  >
                    <div className="font-semibold">
                      {o === "windows" ? "Windows" : "Linux / macOS"}
                    </div>
                    <div className="text-xs text-[var(--text-dim)]">
                      {o === "windows"
                        ? "PowerShell 5.1+"
                        : "PowerShell 7+ (pwsh) + curl"}
                    </div>
                  </button>
                ))}
              </div>
            </div>
            <Footer onNext={() => setStep(2)} onSkip={finish} />
          </>
        )}

        {/* STEP 2 — go to Licenses / create a key */}
        {step === 2 && (
          <>
            <h2 className="text-xl font-bold">Step 1: create a license key</h2>
            <p className="text-sm text-[var(--text-muted)]">
              Each desktop needs its own license key. You&apos;ll paste it when
              the installer runs on your <strong>{osLabel}</strong> machine.
            </p>
            <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-soft)] p-4 text-sm text-[var(--text-muted)]">
              The key is license/entitlements only — it is <strong>not</strong>{" "}
              an AI provider key. Provider keys go on the PC after install.
            </div>
            <Footer
              onBack={() => setStep(1)}
              onNext={() => setStep(3)}
              nextLabel="Next: name the key"
              onSkip={finish}
            />
          </>
        )}

        {/* STEP 3 — name + create the key */}
        {step === 3 && (
          <>
            <h2 className="text-xl font-bold">Name your {osLabel} key</h2>
            <p className="text-sm text-[var(--text-muted)]">
              Give it a name so you can tell your machines apart later.
            </p>
            {error && <div className="alert alert-error">{error}</div>}
            <div className="field !mb-0">
              <label className="label !mb-1 text-xs" htmlFor="keyName">
                Key name
              </label>
              <input
                id="keyName"
                className="input"
                value={keyName}
                onChange={(e) => setKeyName(e.target.value)}
                placeholder={`${os === "windows" ? "Windows" : "Linux"} desktop`}
                maxLength={120}
              />
            </div>
            <Footer
              onBack={() => setStep(2)}
              onNext={createKey}
              nextLabel={creating ? "Creating…" : "Create key"}
              nextDisabled={creating}
              onSkip={finish}
            />
          </>
        )}

        {/* STEP 4 — install command + key (both, so they always have them) */}
        {step === 4 && (
          <>
            <h2 className="text-xl font-bold">Excellent — you&apos;re almost there</h2>
            <p className="text-sm text-[var(--text-muted)]">
              Copy both of these. You&apos;ll need them on your{" "}
              <strong>{osLabel}</strong> desktop.
            </p>
            <CopyField label={`Install command (${osLabel})`} value={installCmd} />
            {fullKey && (
              <CopyField label="Your license key (shown once)" value={fullKey} />
            )}
            <div className="rounded-lg border border-[var(--accent)]/40 bg-[var(--accent-soft)] p-4 text-sm">
              <div className="mb-2 font-semibold text-[var(--accent-strong)]">
                On your {osLabel} desktop:
              </div>
              {os === "windows" ? (
                <ol className="ml-4 grid list-decimal gap-1.5 text-[var(--text-muted)]">
                  <li>
                    Open <strong>PowerShell as Administrator</strong> — click the
                    magnifier / Start, type <code>PowerShell</code>, right-click →{" "}
                    <strong>Run as administrator</strong>.
                  </li>
                  <li>Paste the install command and press Enter.</li>
                  <li>
                    When prompted, paste your <strong>license key</strong>.
                  </li>
                </ol>
              ) : (
                <ol className="ml-4 grid list-decimal gap-1.5 text-[var(--text-muted)]">
                  <li>Open a terminal.</li>
                  <li>Paste the <code>curl</code> install command and press Enter.</li>
                  <li>
                    When prompted, paste your <strong>license key</strong>.
                  </li>
                </ol>
              )}
            </div>
            <p className="text-xs text-[var(--text-dim)]">
              Your key is stored as a hash on our side — keep a copy; it isn&apos;t
              shown again. You can always make another from{" "}
              <Link href="/app/api-keys" className="underline">
                Licenses
              </Link>
              .
            </p>
            <Footer
              onBack={() => setStep(3)}
              onNext={() => setStep(5)}
              nextLabel="I've copied both — Next"
              onSkip={finish}
            />
          </>
        )}

        {/* STEP 5 — look around + donate + done */}
        {step === 5 && (
          <>
            <h2 className="text-xl font-bold">That&apos;s the portal side</h2>
            <p className="text-sm text-[var(--text-muted)]">
              Be sure to look around — <strong>Stats</strong> for your token
              savings, <strong>Licenses</strong> to manage keys,{" "}
              <strong>Change control</strong> for what&apos;s new, and{" "}
              <strong>Bugs</strong> to report anything. The desktop client will
              walk you through the app itself the first time it launches.
            </p>
            <div className="rounded-lg border border-[var(--border)] bg-[var(--bg-soft)] p-4">
              <div className="mb-1 font-semibold">PromptParle is free</div>
              <p className="mb-3 text-sm text-[var(--text-muted)]">
                {SUPPORT.blurb}
              </p>
              <a
                href={SUPPORT.href}
                target="_blank"
                rel="noopener"
                className="btn btn-secondary text-sm"
              >
                ♥ {SUPPORT.label}
              </a>
            </div>
            <div className="flex items-center justify-between gap-3">
              <button
                type="button"
                className="text-sm text-[var(--text-dim)] hover:underline"
                onClick={() => setStep(4)}
              >
                Back
              </button>
              <button type="button" className="btn btn-primary" onClick={finish}>
                Finish — go to dashboard
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function Footer({
  onBack,
  onNext,
  onSkip,
  nextLabel = "Next",
  nextDisabled = false,
}: {
  onBack?: () => void;
  onNext: () => void;
  onSkip: () => void;
  nextLabel?: string;
  nextDisabled?: boolean;
}) {
  return (
    <div className="mt-1 flex items-center justify-between gap-3">
      <div className="flex items-center gap-4">
        {onBack && (
          <button
            type="button"
            className="text-sm text-[var(--text-dim)] hover:underline"
            onClick={onBack}
          >
            Back
          </button>
        )}
        <button
          type="button"
          className="text-sm text-[var(--text-dim)] hover:underline"
          onClick={onSkip}
        >
          Skip setup
        </button>
      </div>
      <button
        type="button"
        className="btn btn-primary"
        onClick={onNext}
        disabled={nextDisabled}
      >
        {nextLabel}
      </button>
    </div>
  );
}
