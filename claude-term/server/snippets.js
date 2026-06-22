import { readFile } from 'node:fs/promises';

// The 6 seed chips (spec §9). `submit:true` fires immediately; default prepends.
export const DEFAULT_SNIPPETS = [
  { label: '🏛️ Council', body: 'Convene the council (council-v2-spec) on this change before committing.' },
  { label: '💡 Brainstorm', body: 'Use the brainstorming skill first — explore intent and design before any code.' },
  { label: '🐛 Debug', body: 'Use systematic-debugging: form a hypothesis and find root cause before proposing a fix.' },
  { label: '📐 Plan only', body: 'Produce a written plan only. Do not edit code until I approve it.' },
  { label: '✅ Verify', body: 'Run the verification commands and show the output before claiming this works.', submit: true },
  { label: '🦙 Local offload', body: 'Offload bulk reads/summaries to the local Ollama tools where it saves main-context tokens.' },
];

export async function loadSnippets(p) {
  try {
    const raw = await readFile(p, 'utf8');
    const arr = JSON.parse(raw);
    if (Array.isArray(arr) && arr.length > 0 && arr.every((c) => c && c.label && c.body)) {
      return arr;
    }
  } catch {
    // fall through to defaults
  }
  return DEFAULT_SNIPPETS;
}
