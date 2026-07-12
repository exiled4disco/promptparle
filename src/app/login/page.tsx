import Link from "next/link";
import { redirect } from "next/navigation";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { OAuthButtons } from "@/components/OAuthButtons";
import { LoginForm } from "./LoginForm";
import { getSessionUser } from "@/lib/auth";
import { listConfiguredOAuthProviders } from "@/lib/oauth";

export const metadata = { title: "Sign in" };

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; next?: string }>;
}) {
  const user = await getSessionUser();
  if (user) redirect("/app");

  const sp = await searchParams;
  const next = sp.next && sp.next.startsWith("/") ? sp.next : "/app";
  const oauthError = sp.error;
  const oauthReady = listConfiguredOAuthProviders().length > 0;

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Welcome back</h1>
          <p className="page-sub">
            {oauthReady
              ? "One click with Google or GitHub, or email if you prefer."
              : "Sign in with your email and password."}
          </p>
          {oauthError && (
            <div className="alert alert-error mt-4">{oauthError}</div>
          )}
          <div className="mt-6">
            <OAuthButtons next={next} mode="signin" />
            <LoginForm />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            New here?{" "}
            <Link href="/register" className="text-[#93b4ff] hover:underline">
              Create account with invitation code
            </Link>
          </p>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
