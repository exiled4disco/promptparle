import { listConfiguredOAuthProviders } from "@/lib/oauth";

type Props = {
  next?: string;
  mode?: "signin" | "signup";
};

/** Server component. only renders providers that have env credentials. */
export function OAuthButtons({ next = "/app", mode = "signin" }: Props) {
  const providers = listConfiguredOAuthProviders();
  if (providers.length === 0) return null;

  const label = mode === "signup" ? "Continue with" : "Sign in with";

  return (
    <div className="mb-5 grid gap-2.5">
      {providers.map((p) => {
        const href = `/api/auth/oauth/${p}?next=${encodeURIComponent(next)}`;
        const name = p === "google" ? "Google" : "GitHub";
        return (
          <a
            key={p}
            href={href}
            className="btn btn-secondary flex w-full items-center justify-center gap-2.5 no-underline"
          >
            {p === "google" ? <GoogleIcon /> : <GitHubIcon />}
            <span>
              {label} {name}
            </span>
          </a>
        );
      })}
      <div className="relative my-1 flex items-center gap-3">
        <div className="h-px flex-1 bg-[var(--border)]" />
        <span className="text-xs text-[var(--text-dim)]">or email</span>
        <div className="h-px flex-1 bg-[var(--border)]" />
      </div>
    </div>
  );
}

function GoogleIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden>
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.3 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 8 3.1l5.7-5.7C34.2 6.1 29.4 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.5-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 16 19 12 24 12c3.1 0 5.8 1.2 8 3.1l5.7-5.7C34.2 6.1 29.4 4 24 4 16.3 4 9.6 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 10-2 13.6-5.2l-6.3-5.3C29.2 35.2 26.7 36 24 36c-5.3 0-9.7-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.3 4.1-4.2 5.5l.1.1 6.3 5.3C39.3 37.3 44 32 44 24c0-1.3-.1-2.5-.4-3.5z"
      />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden
    >
      <path d="M12.3a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2c-3.3.7-4-1.6-4-1.6-.5-1.3-1.3-1.7-1.3-1.7-1-.7.1-.7.1-.7 1.1.1 1.7 1.2 1.7 1.2 1 1.7 2.6 1.2 3.2.9.1-.7.4-1.2.7-1.5-2.6-.3-5.4-1.3-5.4-5.9 0-1.3.5-2.4 1.2-3.2-.1-.3-.5-1.5.1-3.1 0 0 1-.3 3.3 1.2a11.4 11.4 0 0 1 6 0C17.3 4.7 18.3 5 18.3 5c.6 1.6.2 2.8.1 3.1.8.8 1.2 1.9 1.2 3.2 0 4.6-2.8 5.6-5.4 5.9.4.4.8 1.1.8 2.2v3.3c0.3.2.7.8.6A12 12 0 0 0 12.3z" />
    </svg>
  );
}
