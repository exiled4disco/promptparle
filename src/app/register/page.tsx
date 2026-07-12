import Link from "next/link";
import { redirect } from "next/navigation";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { getSessionUser } from "@/lib/auth";
import { RegisterInviteForm } from "./RegisterInviteForm";

export const metadata = { title: "Create account" };

/**
 * Account creation requires a one-time invitation code first.
 * Email invite links (/invite/[token]) remain an alternate path.
 */
export default async function RegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ code?: string }>;
}) {
  const user = await getSessionUser();
  if (user) redirect("/app");

  const sp = await searchParams;
  const initialCode = (sp.code || "").trim().toUpperCase();

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Create your account</h1>
          <p className="page-sub">
            Step 1: enter your invitation code. Step 2: set your password.
            Open registration is not available.
          </p>
          <div className="mt-6">
            <RegisterInviteForm initialCode={initialCode} />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            Need a code?{" "}
            <Link
              href="/request-invite"
              className="text-[#93b4ff] hover:underline"
            >
              Request an invitation
            </Link>
            . Prefer the email link? Open Accept invitation from your invite
            email.{" "}
            <Link href="/login" className="text-[#93b4ff] hover:underline">
              Sign in
            </Link>{" "}
            if you already have an account.
          </p>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
