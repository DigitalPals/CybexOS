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
  for (const content of ['Welcome to your new desktop.', 'Open app launcher', 'Workspace 5', 'Browser preview', 'No installation needed', 'Cybex OS', 'Open Codex model usage', 'Open Claude model usage']) assert.ok(html.includes(content), content);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|Your site is taking shape/);
  assert.match(html, /<title>Cybex OS/);
  assert.match(html, /og:title/);
});

test('production assets and Sites metadata are packaged', async () => {
  for (const width of [1280, 2560, 5120]) await access(new URL(`../dist/client/wallpapers/moon-mountains-${width}.png`, import.meta.url));
  await access(new URL('../dist/client/cybexos-logo.svg', import.meta.url));
  const [packaged, source] = await Promise.all(['../dist/.openai/hosting.json', '../.openai/hosting.json'].map(path => readFile(new URL(path, import.meta.url), 'utf8')));
  assert.deepEqual(JSON.parse(packaged), JSON.parse(source));
  for (const asset of ['cybexos.svg', 'licenses/cybexos-mark.txt', 'providers/codex.svg', 'providers/claude.svg', 'licenses/model-usage-marks.txt', 'favicon.ico', 'favicon.svg', 'apple-touch-icon.png', 'site.webmanifest', 'icon-192.png', 'icon-512.png', 'icon-maskable-192.png', 'icon-maskable-512.png']) {
    await access(new URL(`../dist/client/${asset}`, import.meta.url));
  }
});
