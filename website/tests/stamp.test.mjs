import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { stampAssets } from '../scripts/stamp.mjs';

async function fixture(t, files) {
  const directory = await mkdtemp(join(tmpdir(), 'tamio-stamp-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await Promise.all(Object.entries(files).map(([name, text]) => writeFile(join(directory, name), text)));
  return directory;
}

test('stamps every page, preserves URL options, and leaves external resources alone', async t => {
  const css = 'body { color: #123; }';
  const directory = await fixture(t, {
    'index.html': '<link href="/styles.css?theme=light&amp;v=old#theme" rel="stylesheet"><script src=\'./main.js?mode=demo\'></script><script src="https://cdn.example.com/main.js"></script><link href="//fonts.example.com/font.css" rel="stylesheet">',
    '404.html': '<link rel="stylesheet" href="styles.css">',
    'styles.css': css,
    'main.js': 'console.log("hello");',
  });
  await stampAssets(directory);
  const homepage = await readFile(join(directory, 'index.html'), 'utf8');
  const hash = createHash('sha256').update(css).digest('hex').slice(0, 10);
  assert(homepage.includes(`/styles.css?theme=light&amp;v=${hash}#theme`));
  assert.match(homepage, /\.\/main\.js\?mode=demo&amp;v=[0-9a-f]{10}/);
  assert(homepage.includes('src="https://cdn.example.com/main.js"'));
  assert(homepage.includes('href="//fonts.example.com/font.css"'));
  assert.equal(await readFile(join(directory, '404.html'), 'utf8'), `<link rel="stylesheet" href="styles.css?v=${hash}">`);
});

test('rerunning stamping is stable and a changed asset invalidates only its own URL', async t => {
  const directory = await fixture(t, {
    'index.html': '<link href="/styles.css?v=first"><script src="/main.js?v=old&amp;v=older"></script>',
    'styles.css': 'body {}',
    'main.js': 'const value = 1;',
  });
  await stampAssets(directory);
  const original = await readFile(join(directory, 'index.html'), 'utf8');
  await stampAssets(directory);
  assert.equal(await readFile(join(directory, 'index.html'), 'utf8'), original);
  await writeFile(join(directory, 'main.js'), 'const value = 2;');
  await stampAssets(directory);
  const changed = await readFile(join(directory, 'index.html'), 'utf8');
  assert.equal(changed.match(/<link[^>]+>/)[0], original.match(/<link[^>]+>/)[0]);
  assert.notEqual(changed.match(/<script[^>]+>/)[0], original.match(/<script[^>]+>/)[0]);
  assert.equal((changed.match(/\bv=/g) || []).length, 2);
});

test('a missing local resource fails before writing any HTML', async t => {
  const before = '<link href="/styles.css">';
  const directory = await fixture(t, {
    '404.html': before,
    'index.html': '<script src="/missing.js"></script>',
    'styles.css': 'body {}',
  });
  await assert.rejects(stampAssets(directory), /ENOENT/);
  assert.equal(await readFile(join(directory, '404.html'), 'utf8'), before);
});

test('the deploy shell entry point works from another working directory', async t => {
  const directory = await fixture(t, {
    'index.html': '<link href="/styles.css">',
    'styles.css': 'body {}',
  });
  const wrapper = fileURLToPath(new URL('../stamp.sh', import.meta.url));
  const output = execFileSync('bash', [wrapper, directory], { cwd: tmpdir(), encoding: 'utf8' });
  assert.match(output, /^\/styles\.css\?v=[0-9a-f]{10}\n$/);
  assert.match(await readFile(join(directory, 'index.html'), 'utf8'), /styles\.css\?v=[0-9a-f]{10}/);
});
