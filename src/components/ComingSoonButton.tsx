"use client";

import { useEffect, useId, useState } from "react";

type Props = {
  children: React.ReactNode;
  className?: string;
  title?: string;
  message?: string;
};

export function ComingSoonButton({
  children,
  className = "btn btn-secondary",
  title = "Coming soon",
  message = "The PromptParle desktop client is almost ready. Create a free account today — we’ll open desktop install as soon as it ships.",
}: Props) {
  const [open, setOpen] = useState(false);
  const titleId = useId();

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [open]);

  return (
    <>
      <button type="button" className={className} onClick={() => setOpen(true)}>
        {children}
      </button>

      {open ? (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-[2px]"
          role="presentation"
          onClick={() => setOpen(false)}
        >
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby={titleId}
            className="card w-full max-w-md p-6 shadow-[0_24px_60px_rgba(0,0,0,0.55)]"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="mb-3 inline-flex items-center gap-2 rounded-full border border-[rgba(251,191,36,0.35)] bg-[rgba(251,191,36,0.12)] px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wide text-[var(--warning)]">
              Coming soon
            </div>
            <h2 id={titleId} className="text-xl font-semibold tracking-tight">
              {title}
            </h2>
            <p className="mt-2 text-sm leading-relaxed text-[var(--text-muted)]">
              {message}
            </p>
            <div className="mt-6 flex flex-wrap justify-end gap-2">
              <button
                type="button"
                className="btn btn-secondary"
                onClick={() => setOpen(false)}
              >
                Close
              </button>
              <a href="/register" className="btn btn-primary">
                Create free account
              </a>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
