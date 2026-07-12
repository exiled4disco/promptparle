"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export type AppNavItem = {
  href: string;
  label: string;
  exact?: boolean;
};

function itemActive(item: AppNavItem, pathname: string): boolean {
  if (item.exact || item.href === "/app") {
    return pathname === "/app";
  }
  return pathname === item.href || pathname.startsWith(`${item.href}/`);
}

function linkClass(active: boolean, compact = false): string {
  if (compact) {
    return active
      ? "whitespace-nowrap rounded-lg border border-[var(--accent)] bg-[var(--accent-soft)] px-3 py-1.5 text-xs font-medium text-[var(--accent-strong)]"
      : "whitespace-nowrap rounded-lg border border-[var(--border)] px-3 py-1.5 text-xs text-[var(--text-muted)]";
  }
  return active
    ? "rounded-lg border border-[var(--accent)]/50 bg-[var(--accent-soft)] px-3 py-1.5 text-sm font-medium text-[var(--accent-strong)]"
    : "rounded-lg border border-transparent px-3 py-1.5 text-sm text-[var(--text-muted)] transition hover:bg-white/5 hover:text-[var(--text)]";
}

/** Portal app nav with the current tab highlighted. */
export function AppNav({
  items,
  variant = "desktop",
}: {
  items: AppNavItem[];
  variant?: "desktop" | "mobile";
}) {
  const pathname = usePathname() || "/app";

  if (variant === "mobile") {
    return (
      <nav
        className="container flex gap-1 overflow-x-auto pb-3"
        aria-label="App"
      >
        {items.map((item) => {
          const active = itemActive(item, pathname);
          return (
            <Link
              key={item.href}
              href={item.href}
              className={linkClass(active, true)}
              aria-current={active ? "page" : undefined}
            >
              {item.label}
            </Link>
          );
        })}
      </nav>
    );
  }

  return (
    <nav className="flex items-center gap-1" aria-label="App">
      {items.map((item) => {
        const active = itemActive(item, pathname);
        return (
          <Link
            key={item.href}
            href={item.href}
            className={linkClass(active)}
            aria-current={active ? "page" : undefined}
          >
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}
