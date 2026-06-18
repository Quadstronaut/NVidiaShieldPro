// THE SINGLE SHARED SAMPLER (I7). Exactly one sampling loop per interval,
// fanned out to all SSE subscribers. /proc reads are O(1) in client count.
//
// A module-level singleton (ES modules are cached) holds: the latest snapshot,
// the raw previous samples needed for deltas, and the subscriber set. The timer
// starts on first subscribe OR first one-shot read and stops when idle.

import {
  collectCpu,
  collectMem,
  collectDrive,
  collectNet,
  collectTemps
} from './collectors.js';
import { config } from './config.js';

let timer = null;
let latest = null; // last MetricsSnapshot
let raw = { cpu: null, drive: null, net: null }; // delta state carried tick→tick
let lastTickMs = 0;
let sampling = false;
const subscribers = new Set(); // each is a callback (snapshot) => void
const errorSubs = new Set(); // each is a callback ({message}) => void

async function sampleOnce() {
  if (sampling) return latest; // never overlap ticks
  sampling = true;
  const now = Date.now();
  const dtSec = lastTickMs ? (now - lastTickMs) / 1000 : 0;
  try {
    const [cpu, mem, drive, net, temps] = await Promise.all([
      collectCpu(raw.cpu),
      collectMem(),
      collectDrive(raw.drive, dtSec),
      collectNet(raw.net, dtSec),
      collectTemps()
    ]);
    raw = { cpu: cpu.raw, drive: drive.raw, net: net.raw };
    lastTickMs = now;
    latest = {
      ts: now,
      cpu: cpu.metric,
      mem,
      drive: drive.metric,
      net: net.metric,
      temps,
      sampleIntervalMs: config.intervalMs
    };
    return latest;
  } catch (err) {
    // On a sampler fault, notify error subscribers but DO NOT terminate streams.
    const message = err && err.message ? err.message : String(err);
    for (const cb of errorSubs) {
      try {
        cb({ message });
      } catch {
        /* ignore subscriber errors */
      }
    }
    return latest;
  } finally {
    sampling = false;
  }
}

function ensureTimer() {
  if (timer) return;
  // Prime immediately so the first /api/metrics has fresh deltas on the next tick.
  void sampleOnce();
  timer = setInterval(async () => {
    const snap = await sampleOnce();
    if (snap) {
      for (const cb of subscribers) {
        try {
          cb(snap);
        } catch {
          /* ignore subscriber errors */
        }
      }
    }
  }, config.intervalMs);
  if (typeof timer.unref === 'function') timer.unref();
}

function maybeStop() {
  if (subscribers.size === 0 && timer) {
    clearInterval(timer);
    timer = null;
  }
}

// SSE subscribe. Returns an unsubscribe fn. Keeps the single timer alive while
// at least one client is connected.
export function subscribe(onMetrics, onError) {
  ensureTimer();
  subscribers.add(onMetrics);
  if (onError) errorSubs.add(onError);
  // Push the latest snapshot immediately so a new client isn't blank for a tick.
  if (latest) {
    try {
      onMetrics(latest);
    } catch {
      /* ignore */
    }
  }
  return () => {
    subscribers.delete(onMetrics);
    if (onError) errorSubs.delete(onError);
    maybeStop();
  };
}

// One-shot for /api/metrics. Triggers a sample (so it works with zero SSE
// clients) but reuses the same singleton state — still ONE logical sampler.
export async function getSnapshot() {
  if (!latest) {
    // Two reads so the first one-shot is delta-derived, not a cold 0%.
    await sampleOnce();
    await new Promise((r) => setTimeout(r, Math.min(config.intervalMs, 1000)));
    await sampleOnce();
  } else if (!timer) {
    await sampleOnce();
  }
  return latest;
}
