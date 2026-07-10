import Link from "next/link";
import { redirect } from "next/navigation";
import { Logo } from "@/components/Logo";
import { SiteFooter } from "@/components/SiteFooter";
import { RegisterForm } from "./RegisterForm";
import { getSessionUser } from "@/lib/auth";

export const metadata = { title: "Create account" };

export default async function RegisterPage() {
  const user = await getSessionUser();
  if (user) redirect("/app");

  return (
    <div className="flex min-h-full flex-col">
      <header className="container py-6">
        <Logo />
      </header>
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Create your account</h1>
          <p className="page-sub">
            Set up providers and desktop API keys in a few minutes.
          </p>
          <div className="mt-6">
            <RegisterForm />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            Already have an account?{" "}
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
