import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAuth, parseCookie, COOKIE_NAME } from '../server/auth.js';

test('check: right secret passes, wrong/empty fails', () => {
  const a = createAuth('s3cret');
  assert.equal(a.check('s3cret'), true);
  assert.equal(a.check('nope'), false);
  const empty = createAuth('');
  assert.equal(empty.check(''), false); // empty secret never authenticates
});

test('issue → valid; unknown token invalid; revoke removes', () => {
  const a = createAuth('s');
  const t = a.issue();
  assert.equal(a.valid(t), true);
  assert.equal(a.valid('deadbeef'), false);
  assert.equal(a.valid(undefined), false);
  a.revoke(t);
  assert.equal(a.valid(t), false);
});

test('parseCookie extracts the named cookie', () => {
  assert.equal(parseCookie(`a=1; ${COOKIE_NAME}=abc; b=2`), 'abc');
  assert.equal(parseCookie('a=1; b=2'), null);
  assert.equal(parseCookie(undefined), null);
});
