import Link from "next/link";
import { formatNumber } from "@/lib/format";
import type { PlanLimits } from "@/lib/plans";

type FreePlanToastProps = {
  limits: Pick<
    PlanLimits,
    "dailyRequests" | "originalChars" | "maxProviders"
  >;
};

/**
 * Light bottom-of-viewport note: PromptParle is free for everyone. Not a limit
 * warning — an invitation to support the project if it helps you. Fixed so it
 * stays visible while scrolling the Stats page.
 */
export function FreePlanToast({ limits }: FreePlanToastProps) {
  return (
    <div
      className="pointer-events-none fixed inset-x-0 bottom-0 z-40 flex justify-center p-3 sm:p-4"
      role="status"
      aria-live="polite"
      aria-label="PromptParle is free"
    >
      <div className="pointer-events-auto flex w-full max-w-4xl flex-col gap-3 rounded-2xl border border-[var(--border-strong)] bg-[rgba(10,14,24,0.94)] px-4 py-3 shadow-[0_12px_40px_rgba(0,0,0,0.55)] backdrop-blur-md sm:flex-row sm:items-center sm:justify-between sm:gap-4 sm:px-5 sm:py-3.5">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
            Free for everyone
          </div>
          <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm text-[var(--text)]">
            <span className="text-[var(--text-dim)]">
              No paywall — up to{" "}
              <strong className="font-semibold text-[var(--text)]">
                {formatNumber(limits.maxProviders)}
              </strong>{" "}
              providers on your own keys.
            </span>
            <span className="text-[var(--text-dim)]">
              If it helps you, you can support the project.
            </span>
          </div>
        </div>
        <Link
          href="/pricing"
          className="btn btn-ghost shrink-0 whitespace-nowrap px-5 py-2.5 text-sm"
        >
          Support the project
        </Link>
      </div>
    </div>
  );
}
