"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export type AppNavItem = {
  href: string;
  label: string;
  exact?: boolean;
  /** When set, renders as a dropdown group instead of a direct link. */
  children?: AppNavItem[];
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
        {/* Flatten groups inline on mobile (no dropdowns in a scroll strip). */}
        {items.flatMap((item) =>
          item.children && item.children.length ? item.children : [item]
        ).map((item) => {
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
        if (item.children && item.children.length) {
          const groupActive = item.children.some((c) => itemActive(c, pathname));
          return (
            <div key={item.label} className="relative group">
              <button
                type="button"
                className={linkClass(groupActive) + " inline-flex items-center gap-1"}
                aria-haspopup="true"
              >
                {item.label}
                <span aria-hidden className="text-[0.65em] opacity-70">▾</span>
              </button>
              {/* CSS-only dropdown: shows on hover/focus-within, no JS needed */}
              <div
                className="invisible absolute right-0 top-full z-30 mt-1 min-w-[11rem] rounded-lg border border-[var(--border)] bg-[var(--bg)] p-1 opacity-0 shadow-lg transition group-hover:visible group-hover:opacity-100 group-focus-within:visible group-focus-within:opacity-100"
                role="menu"
              >
                {item.children.map((c) => {
                  const cActive = itemActive(c, pathname);
                  return (
                    <Link
                      key={c.href}
                      href={c.href}
                      role="menuitem"
                      className={
                        "block whitespace-nowrap rounded-md px-3 py-1.5 text-sm " +
                        (cActive
                          ? "bg-[var(--accent-soft)] text-[var(--accent-strong)]"
                          : "text-[var(--text-muted)] hover:bg-white/5 hover:text-[var(--text)]")
                      }
                      aria-current={cActive ? "page" : undefined}
                    >
                      {c.label}
                    </Link>
                  );
                })}
              </div>
            </div>
          );
        }
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
