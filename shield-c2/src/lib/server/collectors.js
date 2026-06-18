// Pure-ish metric collectors. Each reads ONLY from the read-only host bind
// mounts (HOST_PROC / HOST_SYS / HOST_DATA) — never the container's own /proc.
// They take the previous raw sample (for deltas) and return both the public
// metric shape and the raw state to carry forward to the next tick.

import { statfs } from 'node:fs/promises';
import { readText, num, pct } from './util.js';
import { config } from './config.js';

// ---- CPU (/proc/stat two-sample delta) -----------------------------------
// Each cpu line: cpu  user nice system idle iowait irq softirq steal guest...
function parseStat(text) {
  if (!text) return null;
  const lines = text.split('\n');
  const cores = {}; // id -> { total, idle }
  let agg = null;
  let runnable = null;
  let total = null;
  for (const line of lines) {
    if (line.startsWith('cpu')) {
      const parts = line.trim().split(/\s+/);
      const label = parts[0];
      const vals = parts.slice(1).map(Number);
      if (vals.some((v) => !Number.isFinite(v))) continue;
      const idle = (vals[3] ?? 0) + (vals[4] ?? 0); // idle + iowait
      const tot = vals.reduce((a, b) => a + b, 0);
      if (label === 'cpu') {
        agg = { total: tot, idle };
      } else {
        const id = Number(label.slice(3));
        if (Number.isFinite(id)) cores[id] = { total: tot, idle };
      }
    } else if (line.startsWith('procs_running')) {
      runnable = num(line.split(/\s+/)[1]);
    } else if (line.startsWith('procs_blocked')) {
      // total runnable+uninterruptible isn't here; total proc count comes from loadavg.
    }
  }
  return { cores, agg, runnable, total };
}

function usageFromDelta(prev, cur) {
  if (!prev || !cur) return null;
  const dTotal = cur.total - prev.total;
  const dIdle = cur.idle - prev.idle;
  if (dTotal <= 0) return null;
  return pct(((dTotal - dIdle) / dTotal) * 100);
}

export async function collectCpu(prev) {
  const statText = await readText(`${config.hostProc}/stat`);
  const loadText = await readText(`${config.hostProc}/loadavg`);
  const cur = parseStat(statText);
  const ids = cur ? Object.keys(cur.cores).map(Number).sort((a, b) => a - b) : [];

  const perCore = ids.map((id) => {
    const usage = prev && prev.cores[id] ? usageFromDelta(prev.cores[id], cur.cores[id]) : 0;
    return { id, usagePct: usage ?? 0 };
  });
  const aggregatePct =
    prev && cur && cur.agg ? usageFromDelta(prev.agg, cur.agg) ?? 0 : 0;

  // load average + runnable/total proc counts together (I3).
  let load = { one: null, five: null, fifteen: null, runnable: null, total: null };
  if (loadText) {
    const p = loadText.trim().split(/\s+/);
    const procs = (p[3] ?? '').split('/'); // "runnable/total"
    load = {
      one: num(p[0]),
      five: num(p[1]),
      fifteen: num(p[2]),
      runnable: num(procs[0]),
      total: num(procs[1])
    };
  }

  const metric = {
    perCore,
    aggregatePct,
    load,
    coreCount: perCore.length
  };
  return { metric, raw: cur };
}

// ---- Memory (/proc/meminfo) ----------------------------------------------
export async function collectMem() {
  const text = await readText(`${config.hostProc}/meminfo`);
  const m = {};
  if (text) {
    for (const line of text.split('\n')) {
      const [k, v] = line.split(':');
      if (k && v) m[k.trim()] = num(v.trim().replace(/\s*kB$/, ''));
    }
  }
  const totalKb = m.MemTotal ?? null;
  const availableKb = m.MemAvailable ?? null;
  // usedKb = totalKb - availableKb (AC4). null-safe.
  const usedKb =
    totalKb != null && availableKb != null ? totalKb - availableKb : null;
  return {
    totalKb,
    freeKb: m.MemFree ?? null,
    availableKb,
    cachedKb: m.Cached ?? null,
    buffersKb: m.Buffers ?? null,
    usedKb
  };
}

// ---- Drive (statfs on /data + /proc/diskstats; SMART honestly absent) -----
function parseMounts(text, target) {
  if (!text) return null;
  for (const line of text.split('\n')) {
    const f = line.split(/\s+/);
    if (f[1] === target) return f[2]; // fs type field
  }
  return null;
}

async function collectDiskstats(prev, dtSec) {
  // /proc/diskstats fields: major minor name reads ... sectorsRead ... writes ... sectorsWritten ...
  // indices (after name at idx 2): 3=reads, 6=sectorsRead, 7=writes, 10=sectorsWritten
  const text = await readText(`${config.hostProc}/diskstats`);
  const SECTOR = 512;
  const cur = {};
  const out = [];
  if (text) {
    for (const line of text.trim().split('\n')) {
      const f = line.trim().split(/\s+/);
      if (f.length < 11) continue;
      const dev = f[2];
      // Skip loop/ram pseudo-devices; keep real block devices + partitions.
      if (/^(ram|loop|fd)\d/.test(dev)) continue;
      const reads = Number(f[3]);
      const sectorsRead = Number(f[5]);
      const writes = Number(f[7]);
      const sectorsWritten = Number(f[9]);
      if (![reads, sectorsRead, writes, sectorsWritten].every(Number.isFinite)) continue;
      cur[dev] = { reads, writes, readBytes: sectorsRead * SECTOR, writeBytes: sectorsWritten * SECTOR };
    }
  }
  for (const dev of Object.keys(cur)) {
    const p = prev && prev[dev];
    const rate = (a, b) => (p && dtSec > 0 ? Math.max(0, (a - b) / dtSec) : 0);
    out.push({
      dev,
      readsPerSec: Math.round(rate(cur[dev].reads, p?.reads ?? 0)),
      writesPerSec: Math.round(rate(cur[dev].writes, p?.writes ?? 0)),
      readBytesPerSec: Math.round(rate(cur[dev].readBytes, p?.readBytes ?? 0)),
      writeBytesPerSec: Math.round(rate(cur[dev].writeBytes, p?.writeBytes ?? 0))
    });
  }
  return { diskstats: out, raw: cur };
}

export async function collectDrive(prev, dtSec) {
  // ext4 usage via statfs on the bind-mounted host /data (always available, D6).
  let data = {
    mount: '/data',
    fsType: 'ext4',
    totalBytes: null,
    freeBytes: null,
    usedBytes: null,
    usedPct: null
  };
  try {
    const s = await statfs(config.hostData);
    const total = s.blocks * s.bsize;
    const free = s.bavail * s.bsize; // space available to unprivileged users
    const used = total - s.bfree * s.bsize;
    data.totalBytes = total;
    data.freeBytes = free;
    data.usedBytes = used;
    data.usedPct = total > 0 ? pct((used / total) * 100) : null;
  } catch {
    // leave nulls; card still renders (I4)
  }
  const mounts = await readText(`${config.hostProc}/mounts`);
  data.fsType = parseMounts(mounts, '/data') ?? data.fsType;

  const ds = await collectDiskstats(prev, dtSec);

  // SMART: not viable on Tegra eMMC (D6). Always present, never blanks (I4).
  const smart = {
    available: false,
    reason:
      'No ATA SMART on Tegra eMMC; SATA SMART needs CAP_SYS_RAWIO + ata-passthrough this stack lacks. ext4 usage + diskstats are the primary drive signal.'
  };

  return { metric: { data, diskstats: ds.diskstats, smart }, raw: ds.raw };
}

// ---- Network (/proc/net/dev two-sample delta) -----------------------------
export async function collectNet(prev, dtSec) {
  const text = await readText(`${config.hostProc}/net/dev`);
  const cur = {};
  const out = [];
  if (text) {
    const lines = text.split('\n').slice(2); // skip 2 header lines
    for (const line of lines) {
      if (!line.includes(':')) continue;
      const [name, rest] = line.split(':');
      const iface = name.trim();
      const f = rest.trim().split(/\s+/).map(Number);
      const rxBytes = f[0];
      const txBytes = f[8];
      if (!Number.isFinite(rxBytes) || !Number.isFinite(txBytes)) continue;
      cur[iface] = { rxBytes, txBytes };
    }
  }
  for (const iface of Object.keys(cur)) {
    const p = prev && prev[iface];
    const rate = (a, b) => (p && dtSec > 0 ? Math.max(0, (a - b) / dtSec) : 0);
    out.push({
      iface,
      rxBytes: cur[iface].rxBytes,
      txBytes: cur[iface].txBytes,
      rxBytesPerSec: Math.round(rate(cur[iface].rxBytes, p?.rxBytes ?? 0)),
      txBytesPerSec: Math.round(rate(cur[iface].txBytes, p?.txBytes ?? 0))
    });
  }
  return { metric: out, raw: cur };
}

// ---- Temps (/sys/class/thermal/thermal_zone*/) ----------------------------
export async function collectTemps() {
  const out = [];
  // Probe a generous fixed range; absent zones simply read null (degrade, not error).
  for (let i = 0; i < 32; i++) {
    const base = `${config.hostSys}/class/thermal/thermal_zone${i}`;
    const tempText = await readText(`${base}/temp`);
    if (tempText == null) continue;
    const milli = num(tempText.trim());
    if (milli == null) continue;
    const type = (await readText(`${base}/type`))?.trim() ?? `zone${i}`;
    out.push({ zone: i, type, celsius: Math.round((milli / 1000) * 10) / 10 });
  }
  return out; // [] when no zones — not an error (AC2/D7)
}
