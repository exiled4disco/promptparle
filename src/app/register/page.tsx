import Link from "next/link";
import { redirect } from "next/navigation";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { getSessionUser } from "@/lib/auth";
import { RegisterForm } from "./RegisterForm";

export const metadata = { title: "Create account" };

/**
 * Open, self-serve registration (0.32.0 — free for everyone, no invitation gate).
 * Email signup verifies via a link; Google/GitHub skip that. Invitation links
 * (/invite/[token]) still work but are no longer required.
 */
export default async function RegisterPage() {
  const user = await getSessionUser();
  if (user) redirect("/app");

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Create your account</h1>
          <p className="page-sub">
            PromptParle is free. Create an account, then generate a license key
            for each desktop you install it on.
          </p>
          <div className="mt-6">
            <RegisterForm />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            Already have an account?{" "}
            <Link href="/login" className="text-[#93b4ff] hover:underline">
              Sign in
            </Link>
            .
          </p>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
