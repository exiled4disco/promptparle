/** Canonical public site origin (no trailing slash). */
export function siteUrl(): string {
  return (process.env.NEXT_PUBLIC_APP_URL || "https://promptparle.com").replace(
    /\/$/,
    ""
  );
}

export function absoluteUrl(path: string): string {
  const p = path.startsWith("/") ? path : `/${path}`;
  return `${siteUrl()}${p}`;
}
