import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { InstallCommand } from "./InstallCommand";
import { ENTITY, howToInstallJsonLd } from "@/lib/aeo";
import { siteUrl } from "@/lib/site";

export const revalidate = 3600;

const APP_URL = siteUrl();
const REPO = "https://github.com/exiled4disco/promptparle.git";
const INSTALL_PS1 = `irm ${APP_URL}/install.ps1 | iex`;
const INSTALL_SH = `curl -fsSL ${APP_URL}/install.sh | bash`;
/** Safer when curl|bash steals stdin (no interactive prompts). */
const INSTALL_SH_FILE = `curl -fsSL ${APP_URL}/install.sh -o /tmp/pp-install.sh && bash /tmp/pp-install.sh`;
/** Manual: clone yourself, then run the PowerShell installer. */
const INSTALL_GIT_CLONE = `git clone --branch main --single-branch ${REPO} ~/src/promptparle
cd ~/src/promptparle
pwsh -NoProfile -File ./powershell/Install-PromptParle.ps1 -BaseUrl ${APP_URL}`;
/** Update an existing clone. */
const INSTALL_GIT_UPDATE = `cd ~/src/promptparle
git pull --ff-only origin main
pwsh -NoProfile -File ./powershell/Install-PromptParle.ps1 -BaseUrl ${APP_URL}`;
/** One-shot with invite code pre-set (still prompts for API key). */
const INSTALL_SH_ENV = `PROMPTPARLE_INVITATION_CODE='PP-XXXX-XXXX' curl -fsSL ${APP_URL}/install.sh | bash`;

const PAGE_TITLE = "Install PromptParle desktop client";
const PAGE_DESCRIPTION =
  "How to install PromptParle: get an invitation, create a desktop license key (pp_live_), run one command, then set OpenAI/Claude/Gemini/Grok keys on your PC. Local-first chat.";

export const metadata: Metadata = {
  title: {
    absolute: `${PAGE_TITLE} | PromptParle`,
  },
  description: PAGE_DESCRIPTION,
  keywords: [
    "PromptParle install",
    "how to install PromptParle",
    "PromptParle desktop",
    "install PowerShell AI client",
    "pp install",
    "local AI chat install",
  ],
  alternates: {
    canonical: "/install",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
    },
  },
  openGraph: {
    type: "website",
    url: "/install",
    siteName: "PromptParle",
    title: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
  },
};

const STEPS = [
  {
    n: "1",
    title: "Get a code",
    body: "Request an invitation (or use the one we emailed you).",
    href: "/request-invite",
    cta: "Request invite",
  },
  {
    n: "2",
    title: "Create your account + desktop license key",
    body: "Enter the code, set a password, then API Keys → create pp_live_… (shown once). Provider model keys come later on the PC, not in the portal.",
    href: "/register",
    cta: "I have a code",
  },
  {
    n: "3",
    title: "Install, then set provider keys locally",
    body: "Run the install command, paste pp_live_…. Then: pp → ⋯ → Providers → Save on this PC (or Set-PromptParleProviderKey).",
    href: null,
    cta: null,
  },
];

export default function InstallPage() {
  const howTo = howToInstallJsonLd();

  return (
    <div className="flex min-h-full flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(howTo) }}
      />
      <SiteHeader />

      <main className="flex-1">
        <section className="container max-w-3xl py-12 md:py-16">
          <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
            Desktop client
          </p>
          <h1 className="page-title mt-2 !mb-2">Install in one command</h1>
          <p className="aeo-direct-answer page-sub !mx-0 max-w-xl !text-left">
            <strong className="text-[var(--text)]">How to install PromptParle:</strong>{" "}
            get an invitation, create a desktop license key (pp_live_…), run one
            terminal command, then set OpenAI/Claude/Gemini/Grok keys in the
            local UI. The bootstrap is served from this site, then clones
            PromptParle from{" "}
            <a
              href="https://github.com/exiled4disco/promptparle"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              GitHub
            </a>
            . Chat stays on your PC. {ENTITY.access}
          </p>

          {/* Easy path */}
          <ol className="mt-10 grid gap-3">
            {STEPS.map((s) => (
              <li
                key={s.n}
                className="card flex flex-col gap-2 p-4 sm:flex-row sm:items-center sm:gap-4"
              >
                <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full border border-[var(--border)] bg-[var(--accent-soft)] text-sm font-bold text-[var(--accent-strong)]">
                  {s.n}
                </div>
                <div className="min-w-0 flex-1">
                  <h2 className="text-base font-semibold">{s.title}</h2>
                  <p className="mt-0.5 text-sm text-[var(--text-muted)]">
                    {s.body}
                  </p>
                </div>
                {s.href && s.cta && (
                  <Link
                    href={s.href}
                    className="btn btn-secondary shrink-0 !py-1.5 !text-sm"
                  >
                    {s.cta}
                  </Link>
                )}
              </li>
            ))}
          </ol>

          {/* Commands */}
          <div className="mt-10 grid gap-4">
            <h2 className="text-lg font-semibold">Pick your system</h2>
            <p className="text-sm text-[var(--text-muted)]">
              These one-liners only download a thin bootstrap from promptparle.com.
              The real install is{" "}
              <code className="mono text-xs">git clone</code> of the GitHub repo,
              then the PowerShell installer inside it.
            </p>

            <InstallCommand
              label="Windows"
              hint="Needs git + PowerShell · clones from GitHub"
              command={INSTALL_PS1}
            />
            <InstallCommand
              label="Linux / macOS (easy)"
              hint="Needs git + PowerShell 7 (pwsh) · clones from GitHub"
              command={INSTALL_SH}
            />
          </div>

          {/* Advanced / nerd paths, mostly Linux */}
          <details className="mt-8 rounded-xl border border-[var(--border)] bg-[var(--bg-soft)] open:bg-[var(--bg-elevated)]">
            <summary className="cursor-pointer list-none px-4 py-3 text-sm font-semibold text-[var(--text)] marker:content-none [&::-webkit-details-marker]:hidden">
              <span className="flex items-center justify-between gap-2">
                <span>Linux nerds: git clone & other ways</span>
                <span className="text-xs font-normal text-[var(--text-dim)]">
                  optional · same end result
                </span>
              </span>
            </summary>
            <div className="grid gap-4 border-t border-[var(--border)] px-4 py-4">
              <p className="text-sm text-[var(--text-muted)]">
                Prefer full control? Same installer, you drive{" "}
                <code className="mono text-xs">git</code> and{" "}
                <code className="mono text-xs">pwsh</code> yourself. Needs{" "}
                <code className="mono text-xs">git</code> and PowerShell 7 (
                <code className="mono text-xs">pwsh</code>).
              </p>

              <InstallCommand
                label="A. Download script, then run (best if prompts fail)"
                hint="Avoids curl|bash eating stdin so invitation / key prompts work"
                command={INSTALL_SH_FILE}
              />

              <InstallCommand
                label="B. git clone yourself"
                hint="Clone the repo, then run Install-PromptParle.ps1"
                command={INSTALL_GIT_CLONE}
              />

              <InstallCommand
                label="C. Already cloned? git pull + reinstall"
                hint="Default path is ~/src/promptparle"
                command={INSTALL_GIT_UPDATE}
              />

              <InstallCommand
                label="D. One-liner with invite code set"
                hint="Replace PP-XXXX-XXXX with your code · still asks for pp_live_ key"
                command={INSTALL_SH_ENV}
              />

              <div className="rounded-lg border border-[var(--border)] bg-[var(--bg)] p-3 text-xs leading-relaxed text-[var(--text-dim)]">
                <p className="font-medium text-[var(--text-muted)]">
                  Useful env vars (with install.sh)
                </p>
                <ul className="mt-2 list-disc space-y-1 pl-4 mono">
                  <li>PROMPTPARLE_CLONE_PATH=$HOME/src/promptparle</li>
                  <li>PROMPTPARLE_REPO_URL={REPO}</li>
                  <li>PROMPTPARLE_BRANCH=main</li>
                  <li>PROMPTPARLE_INVITATION_CODE=PP-XXXX-XXXX</li>
                  <li>PROMPTPARLE_BASE_URL={APP_URL}</li>
                  <li>PROMPTPARLE_START=1 · start local chat after install</li>
                </ul>
                <p className="mt-3 text-[var(--text-muted)]">
                  After any method:{" "}
                  <code className="mono text-[#93b4ff]">
                    Import-Module PromptParle; pp
                  </code>
                </p>
              </div>
            </div>
          </details>

          <div className="mt-8 rounded-xl border border-[var(--border)] bg-[var(--bg-soft)] p-4 text-sm text-[var(--text-muted)]">
            <p className="font-medium text-[var(--text)]">What the easy command does</p>
            <ul className="mt-2 list-disc space-y-1 pl-5">
              <li>
                Fetches bootstrap from this site (
                <code className="mono text-xs">install.ps1</code> /{" "}
                <code className="mono text-xs">install.sh</code>)
              </li>
              <li>
                Clones{" "}
                <code className="mono text-xs">
                  github.com/exiled4disco/promptparle
                </code>{" "}
                (or updates an existing clone)
              </li>
              <li>Asks for your invitation code, then desktop API key</li>
              <li>
                Start chat with{" "}
                <code className="mono text-xs text-[#93b4ff]">
                  Import-Module PromptParle; pp
                </code>
              </li>
              <li>Local UI on 127.0.0.1 · self-update from the same git flow</li>
            </ul>
          </div>

          <p className="mt-8 text-sm text-[var(--text-dim)]">
            Stuck? See the{" "}
            <Link
              href="/faq"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              FAQ
            </Link>
            {" · "}
            <a
              href="https://github.com/exiled4disco/promptparle/blob/main/powershell/PromptParle/README.md"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              Desktop guide
            </a>
            {" · "}
            <a
              href="https://github.com/exiled4disco/promptparle"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              GitHub
            </a>
          </p>
        </section>
      </main>

      <SiteFooter />
    </div>
  );
}
