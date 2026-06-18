<script>
  import { onMount, onDestroy } from 'svelte';

  let metrics = $state(null);
  let connected = $state(false);
  let streamError = $state(null);

  let containers = $state([]);
  let containerError = $state(null);
  let busy = $state({}); // id -> true while a command is in flight

  let logsOpen = $state(false);
  let logsName = $state('');
  let logsText = $state('');

  let es;
  let pollTimer;

  function fmtBytes(b) {
    if (b == null) return '—';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    let n = b;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${u[i]}`;
  }
  function fmtRate(bps) {
    if (bps == null) return '—';
    return `${fmtBytes(bps)}/s`;
  }

  async function loadContainers() {
    try {
      const r = await fetch('/api/containers');
      if (!r.ok) throw new Error((await r.json()).error ?? r.statusText);
      containers = await r.json();
      containerError = null;
    } catch (e) {
      containerError = e.message;
    }
  }

  async function cmd(id, action) {
    busy = { ...busy, [id]: true };
    try {
      const r = await fetch(`/api/containers/${id}/${action}`, { method: 'POST' });
      if (r.status !== 204) {
        const j = await r.json().catch(() => ({}));
        throw new Error(j.detail ?? j.error ?? r.statusText);
      }
      await loadContainers();
    } catch (e) {
      containerError = `${action} failed: ${e.message}`;
    } finally {
      busy = { ...busy, [id]: false };
    }
  }

  async function showLogs(c) {
    logsName = c.name;
    logsText = 'loading…';
    logsOpen = true;
    try {
      const r = await fetch(`/api/containers/${c.id}/logs?tail=200`);
      logsText = r.ok ? await r.text() : `error: ${r.status}`;
    } catch (e) {
      logsText = `error: ${e.message}`;
    }
  }

  onMount(() => {
    es = new EventSource('/api/stream');
    es.addEventListener('metrics', (ev) => {
      metrics = JSON.parse(ev.data);
      connected = true;
      streamError = null;
    });
    es.addEventListener('error', (ev) => {
      // SSE 'error' is both transport errors (no .data) and our app-level error event.
      if (ev.data) {
        try { streamError = JSON.parse(ev.data).message; } catch { /* ignore */ }
      } else {
        connected = false;
      }
    });
    loadContainers();
    pollTimer = setInterval(loadContainers, 5000);
  });

  onDestroy(() => {
    es?.close();
    clearInterval(pollTimer);
  });
</script>

<svelte:head><title>shield-c2 · 10.0.0.88:8888</title></svelte:head>

<header>
  <h1>shield-c2</h1>
  <span class="status" class:ok={connected}>{connected ? 'live' : 'connecting…'}</span>
  {#if streamError}<span class="err">sampler: {streamError}</span>{/if}
  <span class="note">unauthenticated · LAN only</span>
</header>

<main>
  <!-- CPU -->
  <section class="card">
    <h2>CPU</h2>
    {#if metrics}
      <div class="big">{metrics.cpu.aggregatePct?.toFixed(1)}%</div>
      <div class="cores">
        {#each metrics.cpu.perCore as core}
          <div class="core">
            <span>c{core.id}</span>
            <div class="bar"><div class="fill" style="width:{core.usagePct}%"></div></div>
            <span>{core.usagePct.toFixed(0)}%</span>
          </div>
        {/each}
      </div>
      <div class="load">
        load {metrics.cpu.load.one ?? '—'} / {metrics.cpu.load.five ?? '—'} / {metrics.cpu.load.fifteen ?? '—'}
        · runnable {metrics.cpu.load.runnable ?? '—'}/{metrics.cpu.load.total ?? '—'}
        · {metrics.cpu.coreCount} cores
      </div>
    {:else}<p class="dim">…</p>{/if}
  </section>

  <!-- RAM -->
  <section class="card">
    <h2>RAM</h2>
    {#if metrics}
      {@const m = metrics.mem}
      <div class="big">{fmtBytes((m.usedKb ?? 0) * 1024)}</div>
      <div class="bar wide"><div class="fill" style="width:{m.totalKb ? (100 * (m.usedKb ?? 0) / m.totalKb) : 0}%"></div></div>
      <table class="kv">
        <tbody>
          <tr><td>total</td><td>{fmtBytes((m.totalKb ?? 0) * 1024)}</td></tr>
          <tr><td>used</td><td>{fmtBytes((m.usedKb ?? 0) * 1024)}</td></tr>
          <tr><td>available</td><td>{fmtBytes((m.availableKb ?? 0) * 1024)}</td></tr>
          <tr><td>cached</td><td>{fmtBytes((m.cachedKb ?? 0) * 1024)}</td></tr>
          <tr><td>buffers</td><td>{fmtBytes((m.buffersKb ?? 0) * 1024)}</td></tr>
        </tbody>
      </table>
    {:else}<p class="dim">…</p>{/if}
  </section>

  <!-- DRIVE -->
  <section class="card">
    <h2>Drive</h2>
    {#if metrics}
      {@const d = metrics.drive}
      <div class="big">{d.data.usedPct?.toFixed(1) ?? '—'}%</div>
      <div class="bar wide"><div class="fill" style="width:{d.data.usedPct ?? 0}%"></div></div>
      <div class="dim">{d.data.mount} ({d.data.fsType}) · {fmtBytes(d.data.usedBytes)} / {fmtBytes(d.data.totalBytes)}</div>
      <table class="kv">
        <thead><tr><th>dev</th><th>r/s</th><th>w/s</th><th>read</th><th>write</th></tr></thead>
        <tbody>
          {#each d.diskstats as s}
            <tr><td>{s.dev}</td><td>{s.readsPerSec}</td><td>{s.writesPerSec}</td><td>{fmtRate(s.readBytesPerSec)}</td><td>{fmtRate(s.writeBytesPerSec)}</td></tr>
          {/each}
        </tbody>
      </table>
      <div class="smart">SMART: {d.smart.available ? 'available' : 'unavailable'} — {d.smart.reason}</div>
    {:else}<p class="dim">…</p>{/if}
  </section>

  <!-- NETWORK -->
  <section class="card">
    <h2>Network</h2>
    {#if metrics}
      <table class="kv">
        <thead><tr><th>iface</th><th>↓ rate</th><th>↑ rate</th><th>↓ total</th><th>↑ total</th></tr></thead>
        <tbody>
          {#each metrics.net as n}
            <tr><td>{n.iface}</td><td>{fmtRate(n.rxBytesPerSec)}</td><td>{fmtRate(n.txBytesPerSec)}</td><td>{fmtBytes(n.rxBytes)}</td><td>{fmtBytes(n.txBytes)}</td></tr>
          {/each}
        </tbody>
      </table>
    {:else}<p class="dim">…</p>{/if}
  </section>

  <!-- TEMPS -->
  <section class="card">
    <h2>Temps</h2>
    {#if metrics}
      {#if metrics.temps.length}
        <table class="kv">
          <tbody>
            {#each metrics.temps as t}
              <tr><td>{t.type} (zone {t.zone})</td><td>{t.celsius.toFixed(1)} °C</td></tr>
            {/each}
          </tbody>
        </table>
      {:else}<p class="dim">no thermal zones exposed</p>{/if}
    {:else}<p class="dim">…</p>{/if}
  </section>

  <!-- CONTAINERS -->
  <section class="card wide-card">
    <h2>Containers</h2>
    {#if containerError}<p class="err">{containerError}</p>{/if}
    <table class="containers">
      <thead><tr><th>name</th><th>image</th><th>state</th><th>status</th><th>actions</th></tr></thead>
      <tbody>
        {#each containers as c}
          <tr>
            <td>{c.name}</td>
            <td class="dim">{c.image}</td>
            <td><span class="pill" class:run={c.state === 'running'}>{c.state}</span></td>
            <td class="dim">{c.status}</td>
            <td class="actions">
              <button disabled={busy[c.id]} onclick={() => cmd(c.id, 'start')}>start</button>
              <button disabled={busy[c.id]} onclick={() => cmd(c.id, 'stop')}>stop</button>
              <button disabled={busy[c.id]} onclick={() => cmd(c.id, 'restart')}>restart</button>
              <button onclick={() => showLogs(c)}>logs</button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </section>
</main>

{#if logsOpen}
  <div class="modal" onclick={() => (logsOpen = false)} role="presentation">
    <div class="modal-body" onclick={(e) => e.stopPropagation()} role="presentation">
      <div class="modal-head">
        <strong>logs · {logsName}</strong>
        <button onclick={() => (logsOpen = false)}>close</button>
      </div>
      <pre>{logsText}</pre>
    </div>
  </div>
{/if}

<style>
  :global(body) { margin: 0; background: #0d1117; color: #c9d1d9; font: 14px/1.4 system-ui, sans-serif; }
  header { display: flex; align-items: center; gap: 12px; padding: 12px 20px; border-bottom: 1px solid #21262d; }
  h1 { font-size: 18px; margin: 0; }
  .status { font-size: 12px; padding: 2px 8px; border-radius: 10px; background: #6e2222; }
  .status.ok { background: #1f6f3f; }
  .note { margin-left: auto; font-size: 12px; color: #8b949e; }
  .err { color: #ff7b72; font-size: 12px; }
  main { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; padding: 18px; }
  .card { background: #161b22; border: 1px solid #21262d; border-radius: 8px; padding: 14px; }
  .wide-card { grid-column: 1 / -1; }
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em; color: #8b949e; margin: 0 0 10px; }
  .big { font-size: 30px; font-weight: 600; }
  .dim { color: #8b949e; font-size: 12px; }
  .cores { display: flex; flex-direction: column; gap: 3px; margin: 8px 0; }
  .core { display: grid; grid-template-columns: 28px 1fr 36px; gap: 6px; align-items: center; font-size: 11px; }
  .bar { background: #21262d; border-radius: 3px; height: 7px; overflow: hidden; }
  .bar.wide { height: 10px; margin: 8px 0; }
  .fill { background: #2f81f7; height: 100%; }
  .load { font-size: 12px; color: #8b949e; }
  table.kv { width: 100%; border-collapse: collapse; font-size: 12px; }
  table.kv td, table.kv th { text-align: left; padding: 2px 6px 2px 0; }
  table.kv th { color: #8b949e; font-weight: 500; }
  .smart { font-size: 11px; color: #8b949e; margin-top: 8px; }
  table.containers { width: 100%; border-collapse: collapse; font-size: 13px; }
  table.containers th, table.containers td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #21262d; }
  .pill { padding: 1px 7px; border-radius: 9px; background: #30363d; font-size: 11px; }
  .pill.run { background: #1f6f3f; }
  .actions button { margin-right: 4px; background: #21262d; color: #c9d1d9; border: 1px solid #30363d; border-radius: 5px; padding: 3px 9px; cursor: pointer; font-size: 12px; }
  .actions button:hover { background: #30363d; }
  .actions button:disabled { opacity: 0.4; cursor: default; }
  .modal { position: fixed; inset: 0; background: rgba(0,0,0,0.6); display: flex; align-items: center; justify-content: center; }
  .modal-body { background: #0d1117; border: 1px solid #30363d; border-radius: 8px; width: min(90vw, 900px); max-height: 80vh; display: flex; flex-direction: column; }
  .modal-head { display: flex; justify-content: space-between; align-items: center; padding: 10px 14px; border-bottom: 1px solid #21262d; }
  .modal-head button { background: #21262d; color: #c9d1d9; border: 1px solid #30363d; border-radius: 5px; padding: 3px 10px; cursor: pointer; }
  pre { margin: 0; padding: 14px; overflow: auto; font: 12px/1.4 ui-monospace, monospace; white-space: pre-wrap; }
</style>
