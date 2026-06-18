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

    // Server emits NAMED events: 'hello', 'metrics', 'error'.
    // Must use addEventListener — the default onmessage fires only for
    // unnamed (event: message) events, which this server never sends.
    es.addEventListener('metrics', (ev) => {
      metrics = JSON.parse(ev.data);
      connected = true;
      streamError = null;
    });
    es.addEventListener('hello', (_ev) => {
      // hello fires before the first metrics snapshot; keep connected=false
      // until the first 'metrics' event confirms real data is flowing.
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
  <div class="header-brand">
    <span class="brand-mark">▸</span>
    <h1>shield-c2</h1>
  </div>
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
            <span class="core-label">c{core.id}</span>
            <div class="bar">
              <div class="fill" style="width:{core.usagePct}%"></div>
            </div>
            <span class="core-pct">{core.usagePct.toFixed(0)}%</span>
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
      <div class="bar wide">
        <div class="fill" style="width:{m.totalKb ? (100 * (m.usedKb ?? 0) / m.totalKb) : 0}%"></div>
      </div>
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
  <section class="card drive-card">
    <h2>Drive</h2>
    {#if metrics}
      {@const d = metrics.drive}
      <div class="big">{d.data.usedPct?.toFixed(1) ?? '—'}%</div>
      <div class="bar wide">
        <div class="fill" style="width:{d.data.usedPct ?? 0}%"></div>
      </div>
      <div class="dim">{d.data.mount} ({d.data.fsType}) · {fmtBytes(d.data.usedBytes)} / {fmtBytes(d.data.totalBytes)}</div>
      <table class="kv">
        <thead><tr><th>dev</th><th>size</th><th>r/s</th><th>w/s</th><th>read</th><th>write</th></tr></thead>
        <tbody>
          {#each d.diskstats as s}
            <tr>
              <td>{s.dev}{#if s.mount} · {s.mount}{/if}</td>
              <td>{s.sizeBytes ? fmtBytes(s.sizeBytes) : '—'}</td>
              <td>{s.readsPerSec}</td>
              <td>{s.writesPerSec}</td>
              <td>{fmtRate(s.readBytesPerSec)}</td>
              <td>{fmtRate(s.writeBytesPerSec)}</td>
            </tr>
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
            <tr>
              <td>{n.iface}</td>
              <td class="accent-info">{fmtRate(n.rxBytesPerSec)}</td>
              <td class="accent-success">{fmtRate(n.txBytesPerSec)}</td>
              <td>{fmtBytes(n.rxBytes)}</td>
              <td>{fmtBytes(n.txBytes)}</td>
            </tr>
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
              <tr>
                <td>{t.type} (zone {t.zone})</td>
                <td class:temp-hot={t.celsius >= 80} class:temp-warm={t.celsius >= 60 && t.celsius < 80}>
                  {t.celsius.toFixed(1)} °C
                </td>
              </tr>
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
      <thead>
        <tr><th>name</th><th>image</th><th>state</th><th>status</th><th>actions</th></tr>
      </thead>
      <tbody>
        {#each containers as c}
          <tr>
            <td class="container-name">{c.name}</td>
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
  /* ------------------------------------------------------------------ */
  /* Scarlet Cyberpunk — design token variables                          */
  /* ------------------------------------------------------------------ */
  :global(:root) {
    --bg:             #101116;
    --surface:        #15030c;
    --surface-2:      #1d000a;
    --surface-3:      #3d0018;
    --border:         #2a0a16;
    --border-accent:  #ff0055;

    --text:           #e8d0d8;
    --text-bright:    #ffffff;
    --text-muted:     #ff8ba8;

    --accent-primary: #ff0055;
    --success:        #00ff9c;
    --warn:           #ffff00;
    --warn-amber:     #d97757;
    --info:           #00ffc8;
    --link:           #00a2ff;
    --purple:         #bd5cff;

    --font-mono: "CaskaydiaCove Nerd Font Mono", "Cascadia Code", Consolas, ui-monospace, monospace;
    --font-ui:   "CaskaydiaCove Nerd Font Propo", "Segoe UI", system-ui, sans-serif;
  }

  /* ------------------------------------------------------------------ */
  /* Global reset                                                        */
  /* ------------------------------------------------------------------ */
  :global(*, *::before, *::after) { box-sizing: border-box; }

  :global(body) {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 14px/1.5 var(--font-ui);
    -webkit-font-smoothing: antialiased;
  }

  /* ------------------------------------------------------------------ */
  /* Header                                                              */
  /* ------------------------------------------------------------------ */
  header {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 12px 20px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    /* 2px scarlet top line — signature shell treatment from ScarlettWindhawk */
    border-top: 2px solid var(--accent-primary);
  }

  .header-brand {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .brand-mark {
    color: var(--accent-primary);
    font-size: 18px;
    line-height: 1;
  }

  h1 {
    font-size: 16px;
    font-weight: 700;
    letter-spacing: 0.06em;
    margin: 0;
    color: var(--text-bright);
    text-transform: uppercase;
    font-family: var(--font-mono);
  }

  /* Live / connecting status pill */
  .status {
    font-size: 11px;
    font-family: var(--font-mono);
    padding: 2px 10px;
    border-radius: 10px;
    background: rgba(255, 0, 85, 0.12);
    color: var(--text-muted);
    border: 1px solid rgba(255, 0, 85, 0.4);
    letter-spacing: 0.05em;
  }
  .status.ok {
    background: rgba(0, 255, 156, 0.10);
    color: var(--success);
    border-color: rgba(0, 255, 156, 0.5);
    box-shadow: 0 0 8px rgba(0, 255, 156, 0.25);
  }

  .note {
    margin-left: auto;
    font-size: 11px;
    color: var(--text-muted);
    letter-spacing: 0.03em;
    font-family: var(--font-mono);
  }

  .err {
    color: var(--accent-primary);
    font-size: 12px;
    font-family: var(--font-mono);
  }

  /* ------------------------------------------------------------------ */
  /* Grid layout                                                         */
  /* ------------------------------------------------------------------ */
  main {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(290px, 1fr));
    gap: 16px;
    padding: 20px;
  }

  /* ------------------------------------------------------------------ */
  /* Cards — acrylic-style (dark maroon base with blur)                 */
  /* ------------------------------------------------------------------ */
  .card {
    /* Mirrors Windhawk AcrylicBrush over $surface at ~0.82 opacity */
    background: rgba(29, 0, 10, 0.82);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    border: 1px solid var(--border);
    /* Signature 2px scarlet top accent (taskbar-styler.yaml:13 pattern) */
    border-top: 2px solid var(--accent-primary);
    border-radius: 6px;
    padding: 16px;
    box-shadow: 0 2px 12px rgba(255, 0, 85, 0.06), 0 1px 4px rgba(0, 0, 0, 0.5);
    transition: box-shadow 0.2s ease;
  }

  .card:hover {
    box-shadow: 0 4px 22px rgba(255, 0, 85, 0.14), 0 1px 4px rgba(0, 0, 0, 0.6);
  }

  .wide-card { grid-column: 1 / -1; }
  /* Drive card holds the widest table (diskstats) — give it two tracks */
  .drive-card { grid-column: span 2; }

  /* Card section headings */
  h2 {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.12em;
    color: var(--text-muted);
    margin: 0 0 12px;
    font-family: var(--font-mono);
    font-weight: 600;
  }

  /* ------------------------------------------------------------------ */
  /* Big metric number                                                   */
  /* ------------------------------------------------------------------ */
  .big {
    font-size: 36px;
    font-weight: 700;
    font-family: var(--font-mono);
    color: var(--text-bright);
    letter-spacing: -0.02em;
    line-height: 1.1;
    margin-bottom: 10px;
  }

  /* ------------------------------------------------------------------ */
  /* Muted / secondary text                                              */
  /* ------------------------------------------------------------------ */
  .dim {
    color: var(--text-muted);
    font-size: 12px;
    font-family: var(--font-mono);
  }

  /* ------------------------------------------------------------------ */
  /* CPU core rows                                                       */
  /* ------------------------------------------------------------------ */
  .cores {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin: 10px 0;
  }

  .core {
    display: grid;
    grid-template-columns: 30px 1fr 38px;
    gap: 6px;
    align-items: center;
    font-size: 11px;
    font-family: var(--font-mono);
  }

  .core-label { color: var(--text-muted); }
  .core-pct   { color: var(--text); text-align: right; }

  /* ------------------------------------------------------------------ */
  /* Progress bars                                                       */
  /* ------------------------------------------------------------------ */
  .bar {
    background: var(--border);
    border-radius: 3px;
    height: 6px;
    overflow: hidden;
  }

  .bar.wide {
    height: 8px;
    margin: 8px 0;
  }

  /* Scarlet-to-cyan gradient; the scarlet end is the "hot" side */
  .fill {
    background: linear-gradient(90deg, var(--accent-primary) 0%, var(--info) 100%);
    height: 100%;
    border-radius: 3px;
    transition: width 0.45s ease;
    box-shadow: 0 0 6px rgba(255, 0, 85, 0.35);
  }

  /* ------------------------------------------------------------------ */
  /* Load average line                                                   */
  /* ------------------------------------------------------------------ */
  .load {
    font-size: 11px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    margin-top: 4px;
  }

  /* ------------------------------------------------------------------ */
  /* Key-value tables (RAM, drive, network, temps)                      */
  /* ------------------------------------------------------------------ */
  table.kv {
    width: 100%;
    border-collapse: collapse;
    font-size: 12px;
    font-family: var(--font-mono);
    margin-top: 4px;
  }

  table.kv td,
  table.kv th {
    text-align: left;
    padding: 3px 8px 3px 0;
    vertical-align: middle;
    white-space: nowrap;
  }

  table.kv th {
    color: var(--text-muted);
    font-weight: 600;
    font-size: 10px;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    border-bottom: 1px solid var(--border);
    padding-bottom: 5px;
  }

  /* First column acts as a label */
  table.kv td:first-child {
    color: var(--text-muted);
    white-space: nowrap;
    padding-right: 16px;
  }

  table.kv td:not(:first-child) {
    color: var(--text);
  }

  /* Network rate columns: cyan = download, green = upload */
  .accent-info    { color: var(--info) !important; }
  .accent-success { color: var(--success) !important; }

  /* ------------------------------------------------------------------ */
  /* Temperature states                                                  */
  /* ------------------------------------------------------------------ */
  .temp-warm { color: var(--warn); }
  .temp-hot  { color: var(--accent-primary); font-weight: 700; }

  /* ------------------------------------------------------------------ */
  /* Drive SMART line                                                    */
  /* ------------------------------------------------------------------ */
  .smart {
    font-size: 11px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    margin-top: 10px;
    padding-top: 8px;
    border-top: 1px solid var(--border);
  }

  /* ------------------------------------------------------------------ */
  /* Containers table                                                    */
  /* ------------------------------------------------------------------ */
  table.containers {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
    font-family: var(--font-mono);
  }

  table.containers th {
    text-align: left;
    padding: 6px 10px;
    color: var(--text-muted);
    font-size: 10px;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    border-bottom: 1px solid var(--border-accent);
    font-weight: 600;
  }

  table.containers td {
    text-align: left;
    padding: 7px 10px;
    border-bottom: 1px solid var(--border);
    vertical-align: middle;
  }

  table.containers tbody tr:hover td {
    background: rgba(255, 0, 85, 0.04);
  }

  .container-name {
    color: var(--text-bright);
    font-weight: 600;
  }

  /* Running / stopped badge */
  .pill {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 10px;
    background: rgba(255, 0, 85, 0.12);
    color: var(--text-muted);
    border: 1px solid rgba(255, 0, 85, 0.35);
    font-size: 10px;
    letter-spacing: 0.05em;
    text-transform: uppercase;
    font-family: var(--font-mono);
  }

  .pill.run {
    background: rgba(0, 255, 156, 0.10);
    color: var(--success);
    border-color: rgba(0, 255, 156, 0.45);
    box-shadow: 0 0 5px rgba(0, 255, 156, 0.2);
  }

  /* ------------------------------------------------------------------ */
  /* Container action buttons                                            */
  /* ------------------------------------------------------------------ */
  .actions {
    display: flex;
    gap: 5px;
    flex-wrap: wrap;
  }

  .actions button {
    background: var(--surface-2);
    color: var(--text-muted);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 3px 10px;
    cursor: pointer;
    font-size: 11px;
    font-family: var(--font-mono);
    letter-spacing: 0.04em;
    transition: color 0.15s, border-color 0.15s, background 0.15s, box-shadow 0.15s;
  }

  .actions button:hover:not(:disabled) {
    background: var(--surface-3);
    color: var(--text-bright);
    border-color: var(--accent-primary);
    box-shadow: 0 0 7px rgba(255, 0, 85, 0.3);
  }

  .actions button:disabled {
    opacity: 0.35;
    cursor: default;
  }

  /* ------------------------------------------------------------------ */
  /* Log modal                                                           */
  /* ------------------------------------------------------------------ */
  .modal {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.72);
    display: flex;
    align-items: center;
    justify-content: center;
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    z-index: 100;
  }

  .modal-body {
    background: var(--surface-2);
    border: 1px solid var(--border-accent);
    border-top: 2px solid var(--accent-primary);
    border-radius: 6px;
    width: min(90vw, 900px);
    max-height: 80vh;
    display: flex;
    flex-direction: column;
    box-shadow: 0 8px 40px rgba(255, 0, 85, 0.22), 0 2px 12px rgba(0, 0, 0, 0.8);
  }

  .modal-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 16px;
    border-bottom: 1px solid var(--border);
    color: var(--text-bright);
    font-family: var(--font-mono);
    font-size: 13px;
  }

  .modal-head button {
    background: var(--surface-3);
    color: var(--text-muted);
    border: 1px solid var(--border-accent);
    border-radius: 4px;
    padding: 3px 12px;
    cursor: pointer;
    font-size: 11px;
    font-family: var(--font-mono);
    transition: color 0.15s, background 0.15s;
  }

  .modal-head button:hover {
    color: var(--text-bright);
    background: var(--accent-primary);
    border-color: var(--accent-primary);
  }

  pre {
    margin: 0;
    padding: 16px;
    overflow: auto;
    font: 12px/1.5 var(--font-mono);
    white-space: pre-wrap;
    color: var(--text);
    flex: 1;
    scrollbar-width: thin;
    scrollbar-color: var(--surface-3) var(--surface-2);
  }

  pre::-webkit-scrollbar        { width: 6px; height: 6px; }
  pre::-webkit-scrollbar-track  { background: var(--surface-2); }
  pre::-webkit-scrollbar-thumb  { background: var(--surface-3); border-radius: 3px; }
  pre::-webkit-scrollbar-thumb:hover { background: var(--accent-primary); }
</style>
