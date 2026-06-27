/* claude-term v2 client — renders Claude Code's headless event stream as a
   legible, native, phone-first conversation. No terminal: assistant text is
   markdown, tool calls are collapsible cards, edits are diffs. One WebSocket per
   attached session; the server fans the same stream to every device on it. */
'use strict';

const $ = (id) => document.getElementById(id);
const elSessions = $('sessions'), elTranscript = $('transcript'), elInput = $('input');
const elSend = $('send'), elStop = $('stop'), elPrompts = $('prompts'), elPromptsBtn = $('promptsBtn');
const stModel = $('st-model'), stCtx = $('st-ctx'), stCost = $('st-cost'), stRun = $('st-run');

let ws = null;            // current WebSocket
let sessionId = null;     // attached session id
let openBubble = null;    // the in-progress assistant text bubble (streaming target)
let liveBuffer = '';      // accumulated streaming text for the open bubble
let toolCards = {};       // tool_use id -> {details, input, name}
let sessionCost = 0;      // accumulated $ for the footer
let wantReconnect = false;

/* ---------------- safe markdown (escape first, protect code) ----------------
   Inline code and fenced blocks are replaced with NUL-delimited sentinels
   () before the bold/italic/link passes, then restored — so ordinary
   numbers in the text are never mistaken for placeholders. */
const C0 = '';
function esc(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function inlineMd(t) {
  const codes = [];
  t = t.replace(/`([^`]+)`/g, (m, c) => C0 + 'c' + (codes.push('<code>' + c + '</code>') - 1) + C0);
  t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  t = t.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  t = t.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return t.replace(new RegExp(C0 + 'c(\\d+)' + C0, 'g'), (m, i) => codes[+i]);
}
function renderMarkdown(src) {
  const fences = [];
  src = src.replace(/```(\w*)\n?([\s\S]*?)```/g, (m, lang, code) =>
    '\n' + C0 + 'f' + (fences.push('<pre><code>' + esc(code.replace(/\n$/, '')) + '</code></pre>') - 1) + C0 + '\n');
  const fenceLine = new RegExp('^' + C0 + 'f(\\d+)' + C0 + '$');
  const lines = src.split('\n');
  let html = '', list = null; // list = 'ul' | 'ol' | null
  const closeList = () => { if (list) { html += '</' + list + '>'; list = null; } };
  let para = [];
  const flushPara = () => { if (para.length) { html += '<p>' + inlineMd(esc(para.join(' '))) + '</p>'; para = []; } };
  for (const line of lines) {
    const fence = line.match(fenceLine);
    if (fence) { flushPara(); closeList(); html += fences[+fence[1]]; continue; }
    if (!line.trim()) { flushPara(); closeList(); continue; }
    const h = line.match(/^(#{1,3})\s+(.*)$/);
    if (h) { flushPara(); closeList(); html += '<h' + h[1].length + '>' + inlineMd(esc(h[2])) + '</h' + h[1].length + '>'; continue; }
    const ul = line.match(/^\s*[-*]\s+(.*)$/);
    const ol = line.match(/^\s*\d+\.\s+(.*)$/);
    if (ul || ol) {
      flushPara();
      const want = ul ? 'ul' : 'ol';
      if (list !== want) { closeList(); html += '<' + want + '>'; list = want; }
      html += '<li>' + inlineMd(esc((ul || ol)[1])) + '</li>'; continue;
    }
    closeList(); para.push(line);
  }
  flushPara(); closeList();
  return html;
}

/* ---------------- diff (common prefix/suffix, mark the middle) ---------------- */
function lineDiff(oldStr, newStr) {
  const o = String(oldStr ?? '').split('\n'), n = String(newStr ?? '').split('\n');
  let p = 0; while (p < o.length && p < n.length && o[p] === n[p]) p++;
  let s = 0; while (s < o.length - p && s < n.length - p && o[o.length - 1 - s] === n[n.length - 1 - s]) s++;
  const rows = [];
  for (let i = 0; i < p; i++) rows.push(['ctx', o[i]]);
  for (let i = p; i < o.length - s; i++) rows.push(['del', o[i]]);
  for (let i = p; i < n.length - s; i++) rows.push(['add', n[i]]);
  for (let i = o.length - s; i < o.length; i++) rows.push(['ctx', o[i]]);
  return rows;
}
function diffHtml(file, oldStr, newStr) {
  const rows = lineDiff(oldStr, newStr).slice(0, 400);
  const body = rows.map(([k, t]) => {
    const sign = k === 'add' ? '+' : k === 'del' ? '-' : ' ';
    return '<span class="row ' + (k === 'ctx' ? '' : k) + '">' + esc(sign + ' ' + t) + '</span>';
  }).join('');
  return '<div class="diff"><div class="file">' + esc(file || 'edit') + '</div>' + body + '</div>';
}

/* ---------------- tool summaries ---------------- */
function short(s, n = 120) { s = String(s); return s.length > n ? s.slice(0, n) + '…' : s; }
function toolSummary(name, i) {
  i = i || {};
  switch (name) {
    case 'Bash': return short(i.command || '');
    case 'Read': case 'Edit': case 'Write': case 'NotebookEdit': return short(i.file_path || i.notebook_path || '');
    case 'Glob': return short(i.pattern || '');
    case 'Grep': return short((i.pattern || '') + (i.path ? ' in ' + i.path : ''));
    case 'Task': return short(i.description || i.subagent_type || '');
    case 'WebFetch': return short(i.url || '');
    case 'WebSearch': return short(i.query || '');
    default: return short(Object.keys(i).map((k) => k + '=' + short(String(i[k]), 30)).join(' '));
  }
}

/* ---------------- transcript rendering ---------------- */
function atBottom() { return elTranscript.scrollHeight - elTranscript.scrollTop - elTranscript.clientHeight < 80; }
function scroll() { elTranscript.scrollTop = elTranscript.scrollHeight; }
function clearEmpty() { const e = elTranscript.querySelector('.empty'); if (e) e.remove(); }
function append(node) { const stick = atBottom(); clearEmpty(); elTranscript.appendChild(node); if (stick) scroll(); }

function addUser(text) {
  const d = document.createElement('div'); d.className = 'msg user'; d.textContent = text; append(d);
}
function ensureBubble() {
  if (!openBubble) {
    openBubble = document.createElement('div');
    openBubble.className = 'msg assistant';
    openBubble.innerHTML = '<div class="md streaming"></div>';
    liveBuffer = '';
    append(openBubble);
  }
  return openBubble.querySelector('.md');
}
function appendDelta(text) {
  const md = ensureBubble(); liveBuffer += text;
  md.innerHTML = renderMarkdown(liveBuffer); md.classList.add('streaming');
  if (atBottom()) scroll();
}
function sealAssistant(text) {
  const md = ensureBubble(); // creates a bubble if a tool-first turn streamed nothing
  md.innerHTML = renderMarkdown(text); md.classList.remove('streaming');
  openBubble = null; liveBuffer = '';
  if (atBottom()) scroll();
}
function addThinking(text) {
  const d = document.createElement('details'); d.className = 'msg think';
  d.innerHTML = '<summary>💭 thought</summary><div class="md">' + renderMarkdown(text) + '</div>';
  append(d);
}
function addToolUse(id, name, input) {
  openBubble = null; // any streaming text block is done once a tool is invoked
  const d = document.createElement('details'); d.className = 'tool running'; d.dataset.id = id;
  const sum = toolSummary(name, input);
  d.innerHTML = '<summary><span class="dot">⏺</span><span class="tname">' + esc(name) +
    '</span><span class="tsum">' + esc(sum) + '</span></summary><div class="body"></div>';
  const body = d.querySelector('.body');
  if (name === 'Edit' && input) body.innerHTML = diffHtml(input.file_path, input.old_string, input.new_string);
  else if (name === 'Write' && input) body.innerHTML = diffHtml(input.file_path, '', input.content);
  else body.innerHTML = '<div class="label">input</div><pre>' + esc(JSON.stringify(input, null, 2)) + '</pre>';
  toolCards[id] = { details: d, name, input };
  append(d);
}
function fillToolResult(id, content, isError) {
  const card = toolCards[id]; if (!card) return;
  const d = card.details; d.classList.remove('running'); if (isError) d.classList.add('err');
  const out = document.createElement('div');
  out.innerHTML = '<div class="label">' + (isError ? 'error' : 'result') + '</div><pre>' + esc(short(content || '', 6000)) + '</pre>';
  d.querySelector('.body').appendChild(out);
  if (atBottom()) scroll();
}
function addError(message) {
  const d = document.createElement('div'); d.className = 'msg error'; d.textContent = message; append(d);
}

/* ---------------- status footer ---------------- */
function setStatus(ev) {
  if (ev.model) stModel.textContent = ev.model;
  if (typeof ev.contextLeftPct === 'number') stCtx.textContent = 'ctx ' + ev.contextLeftPct + '%';
  if (typeof ev.running === 'boolean') {
    stRun.textContent = ev.running ? '✻ working…' : '';
    elSend.classList.toggle('hidden', ev.running);
    elStop.classList.toggle('hidden', !ev.running);
  }
}

/* ---------------- event dispatch ---------------- */
function handle(ev) {
  switch (ev.type) {
    case 'attached': break;
    case 'status': setStatus(ev); break;
    case 'user_message': addUser(ev.text); break;
    case 'assistant_delta': if (ev.text && !ev.thinking) appendDelta(ev.text); break;
    case 'assistant_message': sealAssistant(ev.text); break;
    case 'assistant_thinking': addThinking(ev.text); break;
    case 'tool_use': addToolUse(ev.id, ev.name, ev.input); break;
    case 'tool_result': fillToolResult(ev.id, ev.content, ev.isError); break;
    case 'result':
      if (typeof ev.costUsd === 'number') { sessionCost += ev.costUsd; stCost.textContent = '$' + sessionCost.toFixed(4); }
      if (typeof ev.contextLeftPct === 'number') stCtx.textContent = 'ctx ' + ev.contextLeftPct + '%';
      break;
    case 'error': addError(ev.message); break;
  }
}

/* ---------------- websocket ---------------- */
function connect(id) {
  if (ws) { wantReconnect = false; try { ws.close(); } catch (e) {} }
  sessionId = id; openBubble = null; liveBuffer = ''; toolCards = {}; sessionCost = 0;
  elTranscript.innerHTML = ''; stCost.textContent = ''; stCtx.textContent = '';
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(proto + '://' + location.host + '/ws?session=' + encodeURIComponent(id));
  wantReconnect = true;
  ws.onmessage = (e) => { try { handle(JSON.parse(e.data)); } catch (err) {} };
  ws.onclose = () => { if (wantReconnect && sessionId === id) setTimeout(() => { if (sessionId === id) connect(id); }, 1500); };
}

/* ---------------- sending ---------------- */
function send(text) {
  text = (text ?? elInput.value).trim();
  if (!text || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: 'user_message', text }));
  elInput.value = ''; autosize();
}
function interrupt() { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'interrupt' })); }

/* ---------------- sessions ---------------- */
async function loadSessions(select) {
  const list = await fetch('/api/sessions').then((r) => r.json()).catch(() => []);
  elSessions.innerHTML = '';
  if (!list.length) { const o = document.createElement('option'); o.textContent = '— no sessions —'; o.value = ''; elSessions.appendChild(o); }
  for (const s of list) {
    const o = document.createElement('option'); o.value = s.id;
    const tag = (s.clients ? ' 👁' + s.clients : '') + (s.running ? ' ✻' : '');
    o.textContent = s.title + tag;
    elSessions.appendChild(o);
  }
  if (select) elSessions.value = select;
  if (elSessions.value) connect(elSessions.value);
}
async function newSession() {
  const dirs = await fetch('/api/dirs').then((r) => r.json()).catch(() => ['/data/claude']);
  let cwd = dirs[0];
  if (dirs.length > 1) {
    const pick = prompt('Working dir:\n' + dirs.map((d, i) => i + ': ' + d).join('\n'), '0');
    if (pick === null) return;
    cwd = dirs[+pick] || dirs[0];
  }
  const r = await fetch('/api/sessions', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ cwd }) });
  if (!r.ok) { addError('could not create session'); return; }
  const { id } = await r.json();
  await loadSessions(id);
  elInput.focus();
}
async function delSession() {
  const id = elSessions.value; if (!id) return;
  if (!confirm('Delete this session and its transcript?')) return;
  await fetch('/api/sessions/' + encodeURIComponent(id), { method: 'DELETE' });
  wantReconnect = false; sessionId = null; if (ws) try { ws.close(); } catch (e) {}
  elTranscript.innerHTML = '<div class="empty">Pick or start a session.</div>';
  await loadSessions();
}

/* ---------------- prompts (snippet chips) ---------------- */
async function loadPrompts() {
  const chips = await fetch('/api/snippets').then((r) => r.json()).catch(() => []);
  elPrompts.innerHTML = '';
  for (const c of chips) {
    const b = document.createElement('button'); b.textContent = c.label;
    b.onclick = () => {
      if (c.submit) send(c.body);
      else { elInput.value = c.body + (elInput.value ? '\n' + elInput.value : ''); autosize(); elInput.focus(); }
    };
    elPrompts.appendChild(b);
  }
}

/* ---------------- composer wiring ---------------- */
function autosize() {
  elInput.style.height = 'auto';
  elInput.style.height = Math.min(elInput.scrollHeight, window.innerHeight * 0.4) + 'px';
  elSend.disabled = !elInput.value.trim();
}
elInput.addEventListener('input', autosize);
elInput.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
elSend.onclick = () => send();
elStop.onclick = interrupt;
$('new').onclick = newSession;
$('del').onclick = delSession;
$('refresh').onclick = () => loadSessions(elSessions.value);
elSessions.onchange = () => { if (elSessions.value) connect(elSessions.value); };
elPromptsBtn.onclick = () => { elPrompts.classList.toggle('hidden'); elPromptsBtn.classList.toggle('on'); };

/* ---------------- boot ---------------- */
loadPrompts();
loadSessions();
