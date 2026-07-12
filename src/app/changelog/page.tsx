import type { Metadata } from "next";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { Markdown } from "@/components/Markdown";
import { readChangelog } from "@/lib/changelog";
import { getSessionUser } from "@/lib/auth";

export const metadata: Metadata = {
  title: "Change control — PromptParle release history",
  description:
    "PromptParle release notes and version history: what changed in each release of the portal and desktop client.",
  alternates: { canonical: "/changelog" },
};

// Read the file at request time so new releases show without a rebuild.
export const dynamic = "force-dynamic";

export default async function PublicChangelogPage() {
  const [source, user] = await Promise.all([
    readChangelog(),
    getSessionUser().catch(() => null),
  ]);

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader user={user ? { name: user.name, email: user.email } : null} />
      <main className="container flex-1 py-10">
        <div className="mx-auto max-w-3xl">
          <h1 className="page-title !mb-1">Change control</h1>
          <p className="page-sub !mx-0 !mt-0 max-w-2xl text-sm">
            Release history for the PromptParle portal and desktop client.
          </p>
          <div className="mt-6">
            {source ? (
              <Markdown source={source} />
            ) : (
              <p className="text-[var(--text-muted)]">
                Changelog coming soon.
              </p>
            )}
          </div>
        </div>
      </main>
      <SiteFooter />
    </div>
  );
}
