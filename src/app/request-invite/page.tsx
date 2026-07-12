import type { Metadata } from "next";
import { redirect } from "next/navigation";

export const metadata: Metadata = {
  title: "Create a free account",
  description:
    "PromptParle is free and open to sign up. Create a free account at /register, no invitation required.",
  alternates: { canonical: "/register" },
  robots: { index: false, follow: true },
};

/**
 * Registration is open now, so "request an invitation" is obsolete. We keep the
 * route (inbound links / older sitemaps may reference it) but redirect it to the
 * free, open signup at /register. The old RequestInviteForm stays in the folder
 * unused rather than being deleted.
 */
export default function RequestInvitePage() {
  redirect("/register");
}
