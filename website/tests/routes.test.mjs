import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

// The deployed entry is an ES module but the package also contains browser
// scripts. Import its source directly without changing the package module type.
const source = await readFile(new URL('../src/index.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const noAssets = { ASSETS: { fetch() { throw new Error('Redirect should not read static assets'); } } };

test('www canonical redirect preserves the path and query before other routing', async () => {
  const response = await worker.fetch(new Request('https://www.tamio.sh/download?from=nav'), noAssets);
  assert.equal(response.status, 301);
  assert.equal(response.headers.get('Location'), 'https://tamio.sh/download?from=nav');
});

for (const pathname of ['/download', '/download/']) {
  test(`${pathname} redirects to the official latest release`, async () => {
    const response = await worker.fetch(new Request(`https://tamio.sh${pathname}?from=nav`), noAssets);
    assert.equal(response.status, 302);
    assert.equal(response.headers.get('Location'), 'https://github.com/missuo/tamio/releases/latest');
  });
}

for (const [pathname, status] of [['/', 200], ['/styles.css?v=123', 200], ['/download/extra', 404], ['/missing-page', 404]]) {
  test(`${pathname} preserves the assets response and status ${status}`, async () => {
    const request = new Request(`https://tamio.sh${pathname}`);
    const assetResponse = new Response('asset response', { status, headers: { 'X-Asset': 'unchanged' } });
    let calls = 0;
    const response = await worker.fetch(request, { ASSETS: { fetch(received) {
      calls += 1;
      assert.equal(received, request);
      return assetResponse;
    } } });
    assert.equal(calls, 1);
    assert.equal(response, assetResponse);
    assert.equal(response.status, status);
    assert.equal(response.headers.get('X-Asset'), 'unchanged');
  });
}

test('Cloudflare configuration serves the custom 404 after Worker routing', async () => {
  const config = await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8');
  assert.match(config, /"not_found_handling"\s*:\s*"404-page"/);
  assert.match(config, /"run_worker_first"\s*:\s*true/);
  assert.match(config, /"binding"\s*:\s*"ASSETS"/);
});
