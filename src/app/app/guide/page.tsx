import Link from "next/link";
import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { GuideContent } from "@/components/GuideContent";
import { getSessionUser } from "@/lib/auth";

export const metadata = { title: "Guide" };

export default async function AppGuidePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  return (
    <div className="grid gap-4">
      <PageHeader
        title="User guide"
        description={
          <>
            Install, license keys, BYOK, optimize &amp; chat, and the savings
            meter. Also public at{" "}
            <Link
              href="/guide"
              className="text-[var(--accent-strong)] underline underline-offset-2"
            >
              /guide
            </Link>
            .
          </>
        }
      />
      <div className="card p-6">
        <GuideContent showHeader={false} />
      </div>
    </div>
  );
}
