import type { Metadata } from "next";
import { SiteHeader } from "@/components/SiteHeader";
import { SiteFooter } from "@/components/SiteFooter";
import { GuideContent } from "@/components/GuideContent";
import { getSessionUser } from "@/lib/auth";

export const metadata: Metadata = {
  title: "User guide — install, license keys, BYOK & savings",
  description:
    "How to install the PromptParle desktop client, create an account and a per-desktop license key, add your own provider keys (BYOK), optimize and chat, and read the savings meter. Local-first: prompts and keys stay on your PC.",
  alternates: { canonical: "/guide" },
};

export const revalidate = 3600;

export default async function GuidePage() {
  const user = await getSessionUser().catch(() => null);

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader user={user ? { name: user.name, email: user.email } : null} />
      <main className="container flex-1 py-10">
        <GuideContent />
      </main>
      <SiteFooter />
    </div>
  );
}
