import type { ReactNode } from "react";

type PageHeaderProps = {
  title: string;
  description?: ReactNode;
  /** Optional actions under the subtitle (left-aligned) */
  actions?: ReactNode;
  className?: string;
};

/** Left-justified page title + subtitle used across the portal app. */
export function PageHeader({
  title,
  description,
  actions,
  className = "",
}: PageHeaderProps) {
  return (
    <div className={`w-full text-left ${className}`.trim()}>
      <h1 className="page-title !mb-0.5 !text-left">{title}</h1>
      {description ? (
        <p className="page-sub !mx-0 !mt-0 max-w-2xl !text-left text-sm">
          {description}
        </p>
      ) : null}
      {actions ? (
        <div className="mt-3 flex flex-wrap items-center justify-start gap-2">
          {actions}
        </div>
      ) : null}
    </div>
  );
}
