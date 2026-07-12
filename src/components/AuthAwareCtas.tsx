"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

/**
 * Marketing CTAs that adapt after mount if a session cookie exists.
 * Keeps the page statically renderable for crawlers (default: logged-out CTAs).
 */
export function AuthAwareCtas({
  className = "mt-8 flex flex-wrap items-center justify-center gap-3",
}: {
  className?: string;
}) {
  const [authed, setAuthed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    fetch("/api/auth/me", { credentials: "include", cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (cancelled) return;
        if (data?.user?.id) setAuthed(true);
      })
      .catch(() => {
        /* public page; ignore */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (authed) {
    return (
      <div className={className}>
        <Link href="/app" className="btn btn-primary">
          Go to dashboard
        </Link>
        <Link href="/install" className="btn btn-ghost">
          Install desktop client
        </Link>
      </div>
    );
  }

  return (
    <div className={className}>
      <Link href="/register" className="btn btn-primary">
        Create free account
      </Link>
      <Link href="/login" className="btn btn-secondary">
        Sign in
      </Link>
      <Link href="/install" className="btn btn-ghost">
        Install desktop client
      </Link>
    </div>
  );
}
