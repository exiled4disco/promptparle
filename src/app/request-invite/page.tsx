import Link from "next/link";
import type { Metadata } from "next";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { RequestInviteForm } from "./RequestInviteForm";

export const revalidate = 3600;

export const metadata: Metadata = {
  title: "Request invitation",
  description:
    "Request an invitation to PromptParle. AI context optimization gateway. Invitation-only access.",
  alternates: { canonical: "/request-invite" },
  robots: { index: true, follow: true },
};

export default function RequestInvitePage() {
  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Request an invitation</h1>
          <p className="page-sub">
            Soft opening, not secrecy, we pace seats so onboarding stays sharp while
            we scale. Tell us who you are; if we can take great care of you, you get
            a one-time code by email.
          </p>
          <div className="mt-6">
            <RequestInviteForm />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            Already have a code?{" "}
            <Link href="/register" className="text-[#93b4ff] hover:underline">
              Create account
            </Link>
            {" · "}
            <Link href="/login" className="text-[#93b4ff] hover:underline">
              Sign in
            </Link>
          </p>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
