import Link from "next/link";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { ResetPasswordForm } from "./ResetPasswordForm";

export const metadata = { title: "Reset password" };

export default async function ResetPasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ token?: string }>;
}) {
  const sp = await searchParams;
  const token = sp.token || "";

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Choose a new password</h1>
          <p className="page-sub">
            Use at least 8 characters. You&apos;ll be signed in after saving.
          </p>
          <div className="mt-6">
            {token ? (
              <ResetPasswordForm token={token} />
            ) : (
              <div className="alert alert-error">
                Missing reset token. Open the link from your email, or{" "}
                <Link href="/forgot-password" className="underline">
                  request a new link
                </Link>
                .
              </div>
            )}
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
