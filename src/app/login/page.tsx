import Link from "next/link";
import { redirect } from "next/navigation";
import { Logo } from "@/components/Logo";
import { LoginForm } from "./LoginForm";
import { getSessionUser } from "@/lib/auth";

export const metadata = { title: "Sign in" };

export default async function LoginPage() {
  const user = await getSessionUser();
  if (user) redirect("/app");

  return (
    <div className="flex min-h-full flex-col">
      <header className="container py-6">
        <Logo />
      </header>
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Welcome back</h1>
          <p className="page-sub">Sign in to manage providers, API keys, and usage.</p>
          <div className="mt-6">
            <LoginForm />
          </div>
          <p className="mt-6 text-center text-sm text-[var(--text-muted)]">
            No account?{" "}
            <Link href="/register" className="text-[#93b4ff] hover:underline">
              Create one
            </Link>
          </p>
        </div>
      </main>
    </div>
  );
}
