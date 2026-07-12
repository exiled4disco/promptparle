"use client";

import { useEffect, useRef, useState } from "react";

type Stat = {
  value: number;
  suffix?: string;
  prefix?: string;
  label: string;
  decimals?: number;
};

function easeOutCubic(t: number) {
  return 1 - Math.pow(1 - t, 3);
}

function useCountUp(target: number, active: boolean, durationMs = 1600, decimals = 0) {
  const [n, setN] = useState(0);
  useEffect(() => {
    if (!active) return;
    let raf = 0;
    const start = performance.now();
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / durationMs);
      const v = target * easeOutCubic(t);
      setN(decimals > 0 ? Number(v.toFixed(decimals)) : Math.round(v));
      if (t < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [target, active, durationMs, decimals]);
  return n;
}

function StatCell({
  stat,
  active,
}: {
  stat: Stat;
  active: boolean;
}) {
  const n = useCountUp(stat.value, active, 1600, stat.decimals ?? 0);
  const formatted =
    (stat.prefix || "") +
    (stat.decimals
      ? n.toFixed(stat.decimals)
      : n.toLocaleString()) +
    (stat.suffix || "");

  return (
    <div className="w-full rounded-2xl border border-[var(--border)] bg-[var(--bg-elevated)]/80 px-4 py-5 text-center">
      <div className="bg-gradient-to-r from-[#5b8cff] via-[#7c5cff] to-[#34d399] bg-clip-text text-3xl font-extrabold tracking-tight text-transparent md:text-4xl">
        {formatted}
      </div>
      <div className="mt-2 text-xs font-medium uppercase tracking-wide text-[var(--text-dim)] md:text-sm md:normal-case md:tracking-normal">
        {stat.label}
      </div>
    </div>
  );
}

export function CountUpStats({ stats }: { stats: Stat[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const [active, setActive] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setActive(true);
          io.disconnect();
        }
      },
      { threshold: 0.25 }
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  const colClass =
    stats.length <= 3
      ? "grid-cols-1 sm:grid-cols-3 max-w-3xl"
      : "grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 max-w-4xl";

  return (
    <div
      ref={ref}
      className={`mx-auto mt-12 grid w-full justify-items-center gap-3 ${colClass}`}
    >
      {stats.map((s) => (
        <StatCell key={s.label} stat={s} active={active} />
      ))}
    </div>
  );
}
