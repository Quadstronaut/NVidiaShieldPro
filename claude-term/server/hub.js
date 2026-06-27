// Per-session hub (spec D3/D6). Owns at most ONE Claude Code turn-process per
// session and fans its event stream out to EVERY attached WebSocket — so two
// phones on the same session see the same live stream and either can drive it
// (NI4 remote-control + multi-attach). Buffers a normalized transcript so a
// freshly-attached (or post-restart) client replays full history before going
// live (NI5). New sessions are remote-controllable the instant they exist — no
// per-session enable step.
import { runTurn } from './agent.js';
import {
  createSession as storeCreate, deleteSession as storeDelete,
  listSessions as storeList, loadTranscript, readSessionCwd, validId,
} from './sessions.js';

export function createHub({ workspace, skipPermissions = true }) {
  const sessions = new Map(); // id -> { id, cwd, model, slashCommands, clients:Set, transcript:[], running, turn, queue }

  function shell(id, cwd) {
    return { id, cwd, model: null, slashCommands: [], clients: new Set(), transcript: [], running: false, turn: null, queue: [] };
  }

  function send(ws, ev) { try { ws.send(JSON.stringify(ev)); } catch { /* socket gone */ } }

  function broadcast(s, ev) {
    if (!ev.ephemeral && ev.type !== 'status') s.transcript.push(ev); // status is derived state, not history
    if (ev.type === 'status') {
      if (ev.model) s.model = ev.model;
      if (ev.slashCommands?.length) s.slashCommands = ev.slashCommands;
      if (typeof ev.running === 'boolean') s.running = ev.running;
    }
    for (const ws of s.clients) send(ws, ev);
  }

  async function hydrate(id) {
    if (sessions.has(id)) return sessions.get(id);
    // Resume a persisted session whose process isn't live (e.g. after restart):
    // read its cwd from disk, replay its stored transcript into the buffer.
    const cwd = (await readSessionCwd(id)) || workspace;
    const s = shell(id, cwd);
    s.transcript = await loadTranscript(id);
    sessions.set(id, s);
    return s;
  }

  function startTurn(s, text) {
    s.running = true;
    const { kill, done } = runTurn({
      cwd: s.cwd, sessionId: s.id, text, skipPermissions,
      onEvent: (ev) => broadcast(s, ev),
    });
    s.turn = { kill };
    done.then(() => {
      s.turn = null;
      s.running = false;
      const next = s.queue.shift();
      if (next) startTurn(s, next); // drain queued messages in order
      else broadcast(s, { type: 'status', running: false });
    });
  }

  function userMessage(s, text) {
    if (typeof text !== 'string' || !text.trim()) return;
    broadcast(s, { type: 'user_message', text }); // echo to all attached clients + record
    if (s.running) s.queue.push(text); // Claude serializes a turn; queue the next
    else startTurn(s, text);
  }

  return {
    // Register a freshly-created session so it's controllable before first attach.
    register({ id, cwd }) {
      if (!sessions.has(id)) sessions.set(id, shell(id, cwd));
      return id;
    },

    async createSession({ cwd }) {
      const { id, cwd: safe } = await storeCreate({ cwd, workspace });
      sessions.set(id, shell(id, safe));
      return { id, cwd: safe };
    },

    async attach(ws, id) {
      const s = await hydrate(id);
      s.clients.add(ws);
      // Replay history, then current status, then go live.
      send(ws, { type: 'attached', id, cwd: s.cwd, clients: s.clients.size });
      for (const ev of s.transcript) send(ws, ev);
      send(ws, { type: 'status', running: s.running, model: s.model, slashCommands: s.slashCommands });

      ws.on('message', (raw) => {
        let m; try { m = JSON.parse(raw.toString()); } catch { return; }
        if (m.type === 'user_message') userMessage(s, m.text);
        else if (m.type === 'slash_command') userMessage(s, m.command); // Claude reads /cmds in the prompt
        else if (m.type === 'interrupt') { if (s.turn) s.turn.kill(); s.queue.length = 0; }
      });
      ws.on('close', () => { s.clients.delete(ws); });
    },

    async listSessions() {
      const persisted = await storeList();
      const byId = new Map(persisted.map((p) => [p.id, p]));
      // Overlay live state; include in-memory-only sessions not yet on disk.
      for (const [id, s] of sessions) {
        const base = byId.get(id) || { id, title: '(new session)', cwd: s.cwd, lastActive: Date.now() };
        byId.set(id, { ...base, running: s.running, clients: s.clients.size });
      }
      return [...byId.values()].sort((a, b) => (b.lastActive || 0) - (a.lastActive || 0));
    },

    async deleteSession(id) {
      if (!validId(id)) throw new Error('invalid session id');
      const s = sessions.get(id);
      if (s) {
        if (s.turn) s.turn.kill();
        for (const ws of s.clients) { try { ws.close(1000, 'session deleted'); } catch { /* gone */ } }
        sessions.delete(id);
      }
      return storeDelete(id);
    },

    hasSession(id) { return validId(id); }, // any valid uuid is attachable (hydrated on demand)
  };
}
