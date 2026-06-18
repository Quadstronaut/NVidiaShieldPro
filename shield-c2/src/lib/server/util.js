import { readFile } from 'node:fs/promises';

// Read a host /proc or /sys file as text. Returns null (never throws) when the
// path is absent so collectors can degrade gracefully instead of blanking cards.
export async function readText(path) {
  try {
    return await readFile(path, 'utf8');
  } catch {
    return null;
  }
}

// Coerce to a finite number or null. Used everywhere a metric may be missing.
export function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

// Clamp a percentage to 0..100 and round to one decimal. Guards against tiny
// negative deltas (clock jitter) and >100 from rounding.
export function pct(v) {
  if (!Number.isFinite(v)) return null;
  return Math.round(Math.min(100, Math.max(0, v)) * 10) / 10;
}
