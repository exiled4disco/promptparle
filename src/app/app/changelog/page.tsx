import Link from "next/link";
import { PageHeader } from "@/components/PageHeader";
import { Markdown } from "@/components/Markdown";
import { readChangelog } from "@/lib/changelog";

export const metadata = { title: "Change control" };

// Read at request time so new releases show without a portal rebuild.
export const dynamic = "force-dynamic";

export default async function ChangelogPage() {
  const source = await readChangelog();

  return (
    <div className="grid gap-4">
      <PageHeader
        title="Change control"
        description={
          <>
            Release history for the portal and desktop client. Also public at{" "}
            <Link
              href="/changelog"
              className="text-[var(--accent-strong)] underline underline-offset-2"
            >
              /changelog
            </Link>
            .
          </>
        }
      />
      <div className="card p-6">
        {source ? (
          <Markdown source={source} />
        ) : (
          <p className="text-[var(--text-muted)]">Changelog coming soon.</p>
        )}
      </div>
    </div>
  );
}
