"use client";

import { useMemo, useState } from "react";
import type { FaqItem } from "@/lib/faq";
import { FAQ_CATEGORIES } from "@/lib/faq";

function itemKey(item: FaqItem): string {
  return `${item.category}::${item.q}`;
}

/**
 * Interactive FAQ list. All Q&A stay in the DOM (details/summary) for SEO crawlers
 * even when filtered visually.
 */
export function FaqList({ items }: { items: FaqItem[] }) {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string>("All");

  const visibleKeys = useMemo(() => {
    const q = query.trim().toLowerCase();
    const set = new Set<string>();
    for (const item of items) {
      if (category !== "All" && item.category !== category) continue;
      if (q) {
        const hay = `${item.q} ${item.a} ${item.category}`.toLowerCase();
        if (!hay.includes(q)) continue;
      }
      set.add(itemKey(item));
    }
    return set;
  }, [items, query, category]);

  const byCategory = useMemo(() => {
    const map = new Map<string, FaqItem[]>();
    for (const cat of FAQ_CATEGORIES) map.set(cat, []);
    for (const item of items) {
      const list = map.get(item.category) || [];
      list.push(item);
      map.set(item.category, list);
    }
    return map;
  }, [items]);

  return (
    <div className="grid gap-8">
      <div
        className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
        role="search"
      >
        <label className="sr-only" htmlFor="faq-search">
          Search frequently asked questions
        </label>
        <input
          id="faq-search"
          type="search"
          className="input w-full sm:max-w-md"
          placeholder="Search questions…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          autoComplete="off"
        />
        <div
          className="flex flex-wrap gap-2"
          role="group"
          aria-label="Filter by category"
        >
          <button
            type="button"
            className={`rounded-full border px-3 py-1 text-xs font-medium transition ${
              category === "All"
                ? "border-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent-strong)]"
                : "border-[var(--border)] text-[var(--text-muted)] hover:text-[var(--text)]"
            }`}
            onClick={() => setCategory("All")}
          >
            All
          </button>
          {FAQ_CATEGORIES.map((c) => (
            <button
              key={c}
              type="button"
              className={`rounded-full border px-3 py-1 text-xs font-medium transition ${
                category === c
                  ? "border-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent-strong)]"
                  : "border-[var(--border)] text-[var(--text-muted)] hover:text-[var(--text)]"
              }`}
              onClick={() => setCategory(c)}
            >
              {c}
            </button>
          ))}
        </div>
      </div>

      <p className="text-sm text-[var(--text-dim)]" aria-live="polite">
        Showing {visibleKeys.size} of {items.length} questions
        {category !== "All" ? ` in ${category}` : ""}
        {query.trim() ? ` matching “${query.trim()}”` : ""}.
      </p>

      {FAQ_CATEGORIES.map((cat) => {
        const catItems = byCategory.get(cat) || [];
        if (catItems.length === 0) return null;
        const anyVisible = catItems.some((i) => visibleKeys.has(itemKey(i)));
        return (
          <section
            key={cat}
            id={`faq-${slug(cat)}`}
            className={anyVisible ? "grid gap-2" : "hidden"}
            aria-labelledby={`faq-heading-${slug(cat)}`}
          >
            <h2
              id={`faq-heading-${slug(cat)}`}
              className="text-sm font-semibold uppercase tracking-wide text-[var(--accent-strong)]"
            >
              {cat}
            </h2>
            <div className="grid gap-2">
              {catItems.map((item) => {
                const key = itemKey(item);
                const show = visibleKeys.has(key);
                const anchor = slug(item.q);
                return (
                  <details
                    key={key}
                    id={anchor}
                    className={`card group overflow-hidden ${show ? "" : "hidden"}`}
                    data-faq-category={item.category}
                    data-faq-question={item.q}
                  >
                    <summary className="cursor-pointer list-none px-4 py-3.5 sm:px-5 [&::-webkit-details-marker]:hidden">
                      <div className="flex items-start justify-between gap-4">
                        <h3 className="font-medium text-[var(--text)]">
                          {item.q}
                        </h3>
                        <span
                          className="mt-0.5 shrink-0 text-lg leading-none text-[var(--text-dim)] transition group-open:rotate-45"
                          aria-hidden
                        >
                          +
                        </span>
                      </div>
                    </summary>
                    <div className="border-t border-[var(--border)] px-4 py-3.5 text-sm leading-relaxed text-[var(--text-muted)] sm:px-5">
                      <p>{item.a}</p>
                    </div>
                  </details>
                );
              })}
            </div>
          </section>
        );
      })}

      {visibleKeys.size === 0 ? (
        <div className="card p-6 text-sm text-[var(--text-muted)]">
          No matches. Try another search or category.
        </div>
      ) : null}
    </div>
  );
}

function slug(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 80);
}
