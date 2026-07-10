import Link from "next/link";
import { redirect } from "next/navigation";
import { Logo } from "@/components/Logo";
import { LogoutButton } from "@/components/LogoutButton";
import { getSessionUser } from "@/lib/auth";

const NAV = [
  { href: "/app", label: "Dashboard", exact: true },
  { href: "/app/providers", label: "Providers" },
  { href: "/app/api-keys", label: "API Keys" },
  { href: "/app/usage", label: "Usage" },
  { href: "/app/settings", label: "Settings" },
];

export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.emailVerifiedAt) {
    redirect(`/verify-email?email=${encodeURIComponent(user.email)}`);
  }

  return (
    <div className="min-h-full">
      <header className="sticky top-0 z-20 border-b border-[var(--border)] bg-[rgba(7,9,15,0.85)] backdrop-blur-md">
        <div className="container flex items-center justify-between gap-4 py-3">
          <div className="flex items-center gap-8">
            <Logo size="sm" />
            <nav className="hidden items-center gap-1 md:flex">
              {NAV.map((item) => (
                <Link
                  key={item.href}
                  href={item.href}
                  className="rounded-lg px-3 py-1.5 text-sm text-[var(--text-muted)] transition hover:bg-white/5 hover:text-[var(--text)]"
                >
                  {item.label}
                </Link>
              ))}
            </nav>
          </div>
          <div className="flex items-center gap-3">
            <div className="hidden text-right sm:block">
              <div className="text-sm font-medium">
                {user.name || user.email}
              </div>
              <div className="text-xs capitalize text-[var(--text-dim)]">
                {user.plan} plan
              </div>
            </div>
            <LogoutButton />
          </div>
        </div>
        <div className="container flex gap-1 overflow-x-auto pb-3 md:hidden">
          {NAV.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="whitespace-nowrap rounded-lg border border-[var(--border)] px-3 py-1.5 text-xs text-[var(--text-muted)]"
            >
              {item.label}
            </Link>
          ))}
        </div>
      </header>
      <main className="container py-8">{children}</main>
    </div>
  );
}
