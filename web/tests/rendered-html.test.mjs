import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, access } from 'node:fs/promises';

// Exercise the deployable Worker bundle, not a source-code snapshot.
test('production Worker renders the desktop and its metadata', async () => {
  const { default: worker } = await import('../dist/server/index.js');
  const response = await worker.fetch(new Request('http://localhost/', { headers: { accept: 'text/html' } }), {
    ASSETS: { fetch: async () => new Response('Not found', { status: 404 }) },
  }, { waitUntil() {}, passThroughOnException() {} });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/html/);
  const html = await response.text();
  for (const content of ['Welcome home', 'Open app launcher', 'Workspace 5', 'WEB PREVIEW', 'No installation needed', 'CybexOS', 'Open Codex model usage', 'Open Claude model usage']) assert.ok(html.includes(content), content);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|Your site is taking shape/);
  assert.match(html, /<title>CybexOS/);
  assert.match(html, /og:title/);
});

test('production assets and Sites metadata are packaged', async () => {
  await access(new URL('../dist/client/wallpapers/moon-mountains.jpg', import.meta.url));
  await access(new URL('../dist/client/cybex-wordmark.svg', import.meta.url));
  const [packaged, source] = await Promise.all(['../dist/.openai/hosting.json', '../.openai/hosting.json'].map(path => readFile(new URL(path, import.meta.url), 'utf8')));
  assert.deepEqual(JSON.parse(packaged), JSON.parse(source));
  for (const asset of ['providers/codex.svg', 'providers/claude.svg', 'licenses/model-usage-marks.txt']) {
    await access(new URL(`../dist/client/${asset}`, import.meta.url));
  }
});
