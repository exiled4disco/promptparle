import Link from "next/link";

/**
 * Floating "Contact us" button, bottom-right — for PUBLIC (marketing) pages only.
 * Logged-in portal users already have the FeedbackButton (bug/suggest forms), so
 * this is gated to public pages via SiteFooter's `showBrand` (true on public,
 * false in the portal). Plain link to /contact — no client JS needed.
 */
export function FloatingContact() {
  return (
    <Link
      href="/contact"
      aria-label="Contact us"
      className="fixed bottom-4 right-4 z-40 inline-flex items-center gap-2 rounded-full border border-[var(--border)] bg-[var(--accent)] px-4 py-2.5 text-sm font-semibold text-[#0b1220] shadow-lg transition hover:brightness-110 sm:bottom-6 sm:right-6"
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden
      >
        <path d="M4 4h16v12H5.17L4 17.17V4z" />
      </svg>
      Contact us
    </Link>
  );
}
