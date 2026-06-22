import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wrapPaste } from '../server/bracketed-paste.js';

const START = '\x1b[200~';
const END = '\x1b[201~';

test('wraps a multi-line body in bracketed-paste markers, no submit', () => {
  const out = wrapPaste('line1\nline2');
  assert.ok(out.startsWith(START));
  assert.ok(out.endsWith(END));
  assert.ok(out.includes('line1\nline2'));
  assert.ok(!out.endsWith('\r'));
});

test('submit:true appends a carriage return after the end marker (D7)', () => {
  const out = wrapPaste('go', true);
  assert.ok(out.endsWith(END + '\r'));
});
