"use client";

import { useCallback, useEffect, useState } from "react";
import type { ProductScreenshot } from "@/lib/product-screenshots";

type ProductCarouselProps = {
  items: ProductScreenshot[];
  /** Auto-advance interval ms (0 = off) */
  intervalMs?: number;
};

export function ProductCarousel({
  items,
  intervalMs = 7000,
}: ProductCarouselProps) {
  const [index, setIndex] = useState(0);
  const [paused, setPaused] = useState(false);
  const n = items.length;
  const current = items[index] ?? items[0];

  const go = useCallback(
    (next: number) => {
      if (n === 0) return;
      setIndex(((next % n) + n) % n);
    },
    [n]
  );

  useEffect(() => {
    if (!intervalMs || paused || n < 2) return;
    const t = window.setInterval(() => go(index + 1), intervalMs);
    return () => window.clearInterval(t);
  }, [intervalMs, paused, n, index, go]);

  if (!current) return null;

  return (
    <div
      className="mx-auto w-full max-w-5xl"
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
    >
      <div className="card overflow-hidden p-0">
        <div className="relative bg-[var(--bg-elevated)]">
          <div className="aspect-[16/11] w-full sm:aspect-[16/10]">
            <picture>
              <source srcSet={`${current.src}.webp`} type="image/webp" />
              <img
                src={`${current.src}.jpg`}
                alt={current.title}
                width={1280}
                height={800}
                className="h-full w-full object-cover object-top"
                loading={index === 0 ? "eager" : "lazy"}
                decoding="async"
              />
            </picture>
          </div>

          <button
            type="button"
            aria-label="Previous screenshot"
            className="absolute left-2 top-1/2 -translate-y-1/2 rounded-full border border-[var(--border)] bg-[rgba(7,9,15,0.75)] px-3 py-2 text-sm text-[var(--text)] backdrop-blur hover:bg-[rgba(7,9,15,0.9)] sm:left-3"
            onClick={() => go(index - 1)}
          >
            ‹
          </button>
          <button
            type="button"
            aria-label="Next screenshot"
            className="absolute right-2 top-1/2 -translate-y-1/2 rounded-full border border-[var(--border)] bg-[rgba(7,9,15,0.75)] px-3 py-2 text-sm text-[var(--text)] backdrop-blur hover:bg-[rgba(7,9,15,0.9)] sm:right-3"
            onClick={() => go(index + 1)}
          >
            ›
          </button>

          <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-[rgba(7,9,15,0.92)] via-[rgba(7,9,15,0.55)] to-transparent px-4 pb-4 pt-12 sm:px-6">
            <div className="flex flex-wrap items-end justify-between gap-2">
              <div>
                <p className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
                  {current.group === "desktop" ? "Desktop client" : "Portal"}
                </p>
                <h3 className="mt-0.5 text-lg font-semibold text-[var(--text)] sm:text-xl">
                  {current.title}
                </h3>
                <p className="mt-1 max-w-2xl text-sm text-[var(--text-muted)]">
                  {current.caption}
                </p>
              </div>
              <p className="text-xs text-[var(--text-dim)]">
                {index + 1} / {n}
              </p>
            </div>
          </div>
        </div>

        {/* Thumbnail strip */}
        <div className="flex gap-2 overflow-x-auto border-t border-[var(--border)] bg-[var(--bg-soft)]/40 p-3">
          {items.map((item, i) => {
            const active = i === index;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => go(i)}
                aria-label={`Show ${item.title}`}
                aria-current={active ? "true" : undefined}
                className={`relative h-14 w-20 shrink-0 overflow-hidden rounded-md border transition sm:h-16 sm:w-24 ${
                  active
                    ? "border-[var(--accent)] ring-2 ring-[var(--accent-soft)]"
                    : "border-[var(--border)] opacity-70 hover:opacity-100"
                }`}
              >
                <img
                  src={`${item.src}-thumb.jpg`}
                  alt=""
                  className="h-full w-full object-cover object-top"
                  loading="lazy"
                  decoding="async"
                />
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
