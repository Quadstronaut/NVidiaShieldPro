import { test } from 'node:test';
import assert from 'node:assert/strict';

test('smoke: node:test runner is wired', () => {
  assert.equal(1 + 1, 2);
});
