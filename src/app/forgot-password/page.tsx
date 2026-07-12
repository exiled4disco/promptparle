import Link from "next/link";
import { redirect } from "next/navigation";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { ForgotPasswordForm } from "./ForgotPasswordForm";
import { getSessionUser } from "@/lib/auth";

export const metadata = { title: "Forgot password" };

export default async function ForgotPasswordPage() {
  const user = await getSessionUser();
  if (user) redirect("/app");

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Forgot password</h1>
          <p className="page-sub">
            Enter your account email. If it exists, we&apos;ll send a reset link
            (valid 1 hour).
          </p>
          <div className="mt-6">
            <ForgotPasswordForm />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            <Link href="/login" className="text-[#93b4ff] hover:underline">
              Back to sign in
            </Link>
          </p>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
