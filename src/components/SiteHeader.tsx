"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  useCallback,
  useEffect,
  useState,
  type MouseEvent,
} from "react";
import { Logo } from "@/components/Logo";

export type SiteHeaderUser = {
  name?: string | null;
  email?: string | null;
} | null;

type NavItem = {
  id: string;
  href: string;
  label: string;
  /** Match strategy for active state */
  match: "exact" | "prefix" | "hash";
  hash?: string;
};

const PRIMARY_NAV: NavItem[] = [
  { id: "home", href: "/", label: "Home", match: "exact" },
  {
    id: "why",
    href: "/#why",
    label: "Why",
    match: "hash",
    hash: "why",
  },
  {
    id: "product",
    href: "/#product",
    label: "Product",
    match: "hash",
    hash: "product",
  },
  { id: "examples", href: "/examples", label: "Examples", match: "prefix" },
  { id: "pricing", href: "/pricing", label: "Pricing", match: "prefix" },
  { id: "trust", href: "/trust", label: "Trust", match: "prefix" },
  { id: "faq", href: "/faq", label: "FAQ", match: "prefix" },
  { id: "install", href: "/install", label: "Install", match: "prefix" },
];

function navClass(active: boolean, compact = false): string {
  const base = compact
    ? "whitespace-nowrap rounded-lg border px-3 py-1.5 text-xs transition"
    : "rounded-lg px-3 py-1.5 text-sm font-medium transition";
  if (active) {
    return `${base} border-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent-strong)] ${
      compact ? "" : "border border-[var(--accent)]/50"
    }`;
  }
  return `${base} border-[var(--border)] text-[var(--text-muted)] hover:border-[var(--border-strong)] hover:bg-white/5 hover:text-[var(--text)] ${
    compact ? "" : "border border-transparent"
  }`;
}

function readHash(): string {
  if (typeof window === "undefined") return "";
  return window.location.hash.replace(/^#/, "");
}

function isActive(item: NavItem, pathname: string, hash: string): boolean {
  if (item.match === "exact") {
    // Home: landing root only, not when focused on a section hash
    if (pathname !== "/") return false;
    if (hash === "product" || hash === "why" || hash === "not-that") return false;
    return true;
  }
  if (item.match === "prefix") {
    return pathname === item.href || pathname.startsWith(`${item.href}/`);
  }
  if (item.match === "hash") {
    if (pathname !== "/") return false;
    return hash === (item.hash || "");
  }
  return false;
}

/**
 * Shared public marketing header, same tabs on every public page,
 * with the current area highlighted.
 *
 * Hash tabs (Product / Install) need manual handling: Next.js Link often
 * no-ops when already on `/`, so the old hash (and highlight) would stick.
 */
export function SiteHeader({ user = null }: { user?: SiteHeaderUser }) {
  const pathname = usePathname() || "/";
  const router = useRouter();
  const [hash, setHash] = useState("");
  /** Client-resolved session so marketing pages stay static for crawlers. */
  const [sessionUser, setSessionUser] = useState<SiteHeaderUser>(user);

  useEffect(() => {
    setSessionUser(user);
  }, [user]);

  useEffect(() => {
    if (user) return;
    let cancelled = false;
    fetch("/api/auth/me", { credentials: "include", cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (cancelled || !data?.user) return;
        setSessionUser({
          name: data.user.name ?? null,
          email: data.user.email ?? null,
        });
      })
      .catch(() => {
        /* ignore, public chrome */
      });
    return () => {
      cancelled = true;
    };
  }, [user]);

  const syncHash = useCallback(() => {
    setHash(readHash());
  }, []);

  useEffect(() => {
    syncHash();
    window.addEventListener("hashchange", syncHash);
    window.addEventListener("popstate", syncHash);
    return () => {
      window.removeEventListener("hashchange", syncHash);
      window.removeEventListener("popstate", syncHash);
    };
  }, [pathname, syncHash]);

  /** Home: always land on clean `/` (no leftover #product / #get-started). */
  const goHome = useCallback(
    (e: MouseEvent<HTMLAnchorElement>) => {
      e.preventDefault();
      const onHome = window.location.pathname === "/";
      const hasHash = Boolean(window.location.hash);

      if (!onHome) {
        router.push("/");
      } else if (hasHash) {
        // Same path: Link would no-op and leave the hash → highlight stuck
        window.history.pushState(null, "", "/");
        window.dispatchEvent(new Event("popstate"));
      }

      setHash("");
      window.scrollTo({ top: 0, behavior: "smooth" });
    },
    [router]
  );

  /** Product / Install: set hash, scroll, update highlight even if already on `/`. */
  const goSection = useCallback(
    (section: string) => (e: MouseEvent<HTMLAnchorElement>) => {
      e.preventDefault();
      const onHome = window.location.pathname === "/";

      if (!onHome) {
        router.push(`/#${section}`);
        // Ensure hash + highlight after App Router settles
        window.setTimeout(() => {
          if (window.location.pathname === "/") {
            if (window.location.hash !== `#${section}`) {
              window.history.replaceState(null, "", `/#${section}`);
            }
            setHash(section);
            document
              .getElementById(section)
              ?.scrollIntoView({ behavior: "smooth", block: "start" });
          }
        }, 50);
        setHash(section);
        return;
      }

      if (window.location.hash !== `#${section}`) {
        window.history.pushState(null, "", `/#${section}`);
      }
      setHash(section);
      document
        .getElementById(section)
        ?.scrollIntoView({ behavior: "smooth", block: "start" });
    },
    [router]
  );

  function navClick(item: NavItem) {
    if (item.match === "exact") return goHome;
    if (item.match === "hash" && item.hash) return goSection(item.hash);
    return undefined;
  }

  return (
    <header className="sticky top-0 z-30 isolate border-b border-[var(--border)] bg-[var(--bg)]">
      {/* Invitation banner, stays put with the nav while scrolling */}
      <div className="border-b border-[rgba(91,140,255,0.35)] bg-[var(--bg-elevated)]">
        <div className="container flex flex-col items-center justify-center gap-2 py-2 text-center sm:flex-row sm:gap-3">
          <p className="text-sm text-[var(--text)]">
            <strong className="font-semibold">Invitation only.</strong>{" "}
            PromptParle is available by invitation. No open signup.
          </p>
          {!sessionUser && (
            <Link
              href="/request-invite"
              className="inline-flex shrink-0 items-center rounded-full border border-[rgba(91,140,255,0.45)] bg-[var(--bg)] px-3 py-1 text-sm font-medium text-[var(--accent-strong)] hover:border-[var(--accent)] hover:text-[var(--text)]"
            >
              Request an invitation
            </Link>
          )}
        </div>
      </div>

      <div className="bg-[var(--bg)]">
        <div className="container flex items-center justify-between gap-3 py-3">
          <div className="flex min-w-0 items-center gap-6">
            <Logo size="sm" />
            <nav
              className="hidden items-center gap-1 md:flex"
              aria-label="Primary"
            >
              {PRIMARY_NAV.map((item) => {
                const active = isActive(item, pathname, hash);
                const onClick = navClick(item);
                return (
                  <Link
                    key={item.id}
                    href={item.href}
                    onClick={onClick}
                    className={navClass(active)}
                    aria-current={active ? "page" : undefined}
                  >
                    {item.label}
                  </Link>
                );
              })}
            </nav>
          </div>

          <div className="flex shrink-0 items-center gap-2">
            {sessionUser ? (
              <Link href="/app" className="btn btn-primary !py-1.5 !text-sm">
                Open dashboard
              </Link>
            ) : (
              <>
                <Link
                  href="/login"
                  className={navClass(isSignInArea(pathname))}
                  aria-current={isSignInArea(pathname) ? "page" : undefined}
                >
                  Sign in
                </Link>
                <Link
                  href="/request-invite"
                  className={
                    isInviteArea(pathname)
                      ? "btn btn-primary !py-1.5 !text-sm ring-2 ring-[var(--accent)]/40"
                      : "btn btn-primary !py-1.5 !text-sm"
                  }
                  aria-current={isInviteArea(pathname) ? "page" : undefined}
                >
                  Get invited
                </Link>
              </>
            )}
          </div>
        </div>

        {/* Mobile tab strip, same options on every public page */}
        <div className="container flex gap-1 overflow-x-auto pb-3 md:hidden">
          {PRIMARY_NAV.map((item) => {
            const active = isActive(item, pathname, hash);
            const onClick = navClick(item);
            return (
              <Link
                key={`m-${item.id}`}
                href={item.href}
                onClick={onClick}
                className={navClass(active, true)}
                aria-current={active ? "page" : undefined}
              >
                {item.label}
              </Link>
            );
          })}
          {!user && (
            <>
              <Link
                href="/login"
                className={navClass(isSignInArea(pathname), true)}
                aria-current={isSignInArea(pathname) ? "page" : undefined}
              >
                Sign in
              </Link>
              <Link
                href="/request-invite"
                className={navClass(isInviteArea(pathname), true)}
                aria-current={isInviteArea(pathname) ? "page" : undefined}
              >
                Get invited
              </Link>
            </>
          )}
          {user && (
            <Link href="/app" className={navClass(false, true)}>
              Dashboard
            </Link>
          )}
        </div>
      </div>
    </header>
  );
}

function isSignInArea(pathname: string): boolean {
  return (
    pathname === "/login" ||
    pathname.startsWith("/login/") ||
    pathname.startsWith("/forgot-password") ||
    pathname.startsWith("/reset-password") ||
    pathname.startsWith("/verify-email")
  );
}

function isInviteArea(pathname: string): boolean {
  return (
    pathname === "/request-invite" ||
    pathname.startsWith("/request-invite/") ||
    pathname.startsWith("/invite/") ||
    pathname === "/register" ||
    pathname.startsWith("/register/")
  );
}
