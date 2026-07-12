"use client";

import { FormEvent, useState } from "react";

export function ChangePasswordForm({ hasPassword }: { hasPassword: boolean }) {
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    if (newPassword !== confirm) {
      setError("New passwords do not match");
      return;
    }
    if (newPassword.length < 8) {
      setError("New password must be at least 8 characters");
      return;
    }
    setLoading(true);
    try {
      const res = await fetch("/api/auth/password/change", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          currentPassword: hasPassword ? currentPassword : undefined,
          newPassword,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Could not update password");
        return;
      }
      setSuccess(data.message || "Password updated.");
      setCurrentPassword("");
      setNewPassword("");
      setConfirm("");
    } catch {
      setError("Network error. Try again.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <form
      onSubmit={onSubmit}
      className="rounded-lg border border-[var(--border)] px-3 py-3"
    >
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold">
          {hasPassword ? "Change password" : "Set a password"}
        </h2>
        <span className="text-xs text-[var(--text-muted)]">
          {hasPassword
            ? "Other sessions sign out"
            : "Optional, for email login alongside Google/GitHub"}
        </span>
      </div>
      {error && <div className="alert alert-error mb-3">{error}</div>}
      {success && <div className="alert alert-info mb-3">{success}</div>}
      <div className="grid gap-3 sm:grid-cols-2">
        {hasPassword && (
          <div className="field !mb-0 sm:col-span-2">
            <label className="label" htmlFor="currentPassword">
              Current password
            </label>
            <input
              id="currentPassword"
              className="input"
              type="password"
              autoComplete="current-password"
              required
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
            />
          </div>
        )}
        <div className="field !mb-0">
          <label className="label" htmlFor="newPassword">
            New password
          </label>
          <input
            id="newPassword"
            className="input"
            type="password"
            autoComplete="new-password"
            required
            minLength={8}
            value={newPassword}
            onChange={(e) => setNewPassword(e.target.value)}
            placeholder="At least 8 characters"
          />
        </div>
        <div className="field !mb-0">
          <label className="label" htmlFor="confirmPassword">
            Confirm new password
          </label>
          <input
            id="confirmPassword"
            className="input"
            type="password"
            autoComplete="new-password"
            required
            minLength={8}
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
          />
        </div>
      </div>
      <div className="mt-3 flex justify-end">
        <button
          type="submit"
          className="btn btn-secondary !px-4 !py-2 text-sm"
          disabled={loading}
        >
          {loading
            ? "Saving…"
            : hasPassword
              ? "Update password"
              : "Set password"}
        </button>
      </div>
    </form>
  );
}
