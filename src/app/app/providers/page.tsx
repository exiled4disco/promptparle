import { redirect } from "next/navigation";
import Link from "next/link";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { listProviderCredentials } from "@/lib/providers";
import { PROVIDERS } from "@/lib/constants";
import { ProvidersClient } from "./ProvidersClient";

export const metadata = { title: "Providers" };

export default async function ProvidersPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const credentials = await listProviderCredentials(user.id);

  return (
    <div className="grid gap-6">
      <PageHeader
        title="AI providers"
        description="Desktop chat (0.25+) keeps OpenAI / Claude / Gemini / Grok keys on your PC. Enter model keys in the local UI (⋯ → Providers), not here."
      />

      <div className="card border-[var(--accent)]/30 bg-[var(--accent-soft)]/40 p-5">
        <h2 className="text-base font-semibold text-[var(--text)]">
          Where to enter provider API keys
        </h2>
        <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
          Model keys (<code className="text-xs">sk-…</code>, Claude, Gemini,
          Grok) are set in the <strong className="text-[var(--text)]">desktop client</strong>, not
          here. They never upload to PromptParle.
        </p>
        <ol className="mt-3 list-decimal space-y-1.5 pl-5 text-sm text-[var(--text-muted)]">
          <li>
            Create a desktop license key under{" "}
            <Link
              href="/app/api-keys"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              API Keys
            </Link>{" "}
            (<code className="text-xs">pp_live_…</code>).
          </li>
          <li>
            Install and run{" "}
            <Link
              href="/install"
              className="font-medium text-[var(--accent-strong)] hover:underline"
            >
              the desktop client
            </Link>
            , then <code className="text-xs">pp</code>.
          </li>
          <li>
            In the local UI: <strong className="text-[var(--text)]">⋯ → Providers</strong> →
            paste key → <strong className="text-[var(--text)]">Save on this PC</strong>.
          </li>
        </ol>
        <p className="mt-3 text-sm text-[var(--text-dim)]">
          PowerShell alternative:{" "}
          <code className="text-xs">
            Set-PromptParleProviderKey -Provider openai -ApiKey &apos;…&apos;
          </code>
        </p>
        <p className="mt-2 text-xs text-[var(--text-dim)]">
          See{" "}
          <Link
            href="/trust"
            className="text-[var(--accent-strong)] hover:underline"
          >
            Trust
          </Link>{" "}
          for the local-first data path.
        </p>
      </div>

      <ProvidersClient
        providers={[...PROVIDERS]}
        credentials={credentials.map((c) => ({
          ...c,
          createdAt: c.createdAt.toISOString(),
          lastUsedAt: c.lastUsedAt?.toISOString() ?? null,
        }))}
      />
    </div>
  );
}
