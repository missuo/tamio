import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, readdir, stat } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const siteDirectory = fileURLToPath(new URL('../', import.meta.url));
const workerRoutes = new Set(['/download', '/download/']);

export async function checkSite(directory = siteDirectory) {
  const publicDirectory = resolve(directory, 'public');
  const pages = new Map();
  for (const filename of (await readdir(publicDirectory)).filter(name => name.endsWith('.html'))) {
    const source = await readFile(resolve(publicDirectory, filename), 'utf8');
    const ids = [...source.matchAll(/\sid\s*=\s*(["'])(.*?)\1/gi)].map(match => match[2]);
    assert.equal(new Set(ids).size, ids.length, `${filename}: duplicate HTML id`);
    pages.set(`/${filename}`, { source, ids: new Set(ids) });
    for (const script of source.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
      if (/\btype\s*=\s*(["'])application\/ld\+json\1/i.test(script[1])) {
        assert.doesNotThrow(() => JSON.parse(script[2]), `${filename}: invalid JSON-LD`);
      }
    }
  }
  assert(pages.has('/index.html'), 'Homepage is missing');
  assert(pages.has('/404.html'), 'Custom 404 page is missing');

  async function checkReference(reference, from, anchor = false) {
    if (!reference || /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(reference)) return;
    const url = new URL(reference.replace(/&amp;/gi, '&'), `https://assets.local${from}`);
    if (workerRoutes.has(url.pathname)) return;
    const pathname = decodeURIComponent(url.pathname.endsWith('/') ? `${url.pathname}index.html` : url.pathname);
    const filename = resolve(publicDirectory, `.${pathname}`);
    assert(!relative(publicDirectory, filename).startsWith('..'), `${from}: reference leaves public directory`);
    assert((await stat(filename).catch(() => null))?.isFile(), `${from}: missing local file ${reference}`);
    if (anchor && url.hash && pages.has(pathname)) {
      assert(pages.get(pathname).ids.has(decodeURIComponent(url.hash.slice(1))), `${from}: missing anchor ${reference}`);
    }
  }

  for (const [filename, { source }] of pages) {
    // Read only actual tags; sample commands and script bodies are not links.
    const markup = source.replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, tag => tag.slice(0, tag.indexOf('>') + 1));
    for (const tag of markup.matchAll(/<[a-z][^>]*>/gi)) {
      for (const attribute of tag[0].matchAll(/\s(src|href)\s*=\s*(["'])(.*?)\2/gi)) {
        await checkReference(attribute[3], filename, attribute[1].toLowerCase() === 'href');
      }
    }
  }
  for (const filename of (await readdir(publicDirectory)).filter(name => name.endsWith('.css'))) {
    const source = await readFile(resolve(publicDirectory, filename), 'utf8');
    for (const match of source.matchAll(/url\(\s*(["']?)(.*?)\1\s*\)/gi)) {
      if (!match[2].startsWith('#')) await checkReference(match[2], `/${filename}`);
    }
  }
  for (const subdirectory of ['public', 'src', 'scripts', 'tests']) {
    for (const name of await readdir(resolve(directory, subdirectory))) {
      if (/\.(?:js|mjs)$/.test(name)) {
        execFileSync(process.execPath, ['--check', resolve(directory, subdirectory, name)], { stdio: 'pipe' });
      }
    }
  }
  return pages.size;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const count = await checkSite();
    console.log(`Checked ${count} HTML pages, local links, anchors, JSON-LD, CSS assets, and JavaScript syntax.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
