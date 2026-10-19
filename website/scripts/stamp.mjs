import { createHash } from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const defaultDirectory = fileURLToPath(new URL('../public/', import.meta.url));

// Version only linked stylesheets and scripts. Keep unrelated query parameters
// and fragments, so cache stamping does not change how an asset is requested.
export async function stampAssets(directory = defaultDirectory) {
  const root = resolve(directory);
  const hashes = new Map();
  const updates = [];
  const references = new Set();
  for (const name of (await readdir(root)).filter(name => name.endsWith('.html')).sort()) {
    const filename = resolve(root, name);
    const source = await readFile(filename, 'utf8');
    const tags = [...source.matchAll(/<(script|link)\b[^>]*>/gi)];
    let result = source;
    for (const tag of tags.reverse()) {
      const attribute = tag[1].toLowerCase() === 'script' ? 'src' : 'href';
      const match = new RegExp(`\\s${attribute}\\s*=\\s*(["'])(.*?)\\1`, 'i').exec(tag[0]);
      if (!match) continue;
      const reference = match[2].replace(/&amp;/gi, '&');
      if (/^(?:[a-z][a-z\d+.-]*:|\/\/|#)/i.test(reference)) continue;
      const url = new URL(reference, 'https://assets.local/');
      if (!/\.(?:css|js)$/i.test(url.pathname)) continue;
      const asset = resolve(root, `.${decodeURIComponent(url.pathname)}`);
      const location = relative(root, asset);
      if (location === '..' || location.startsWith(`..${sep}`)) {
        throw new Error(`${name}: asset leaves public directory: ${reference}`);
      }
      if (!hashes.has(asset)) {
        hashes.set(asset, createHash('sha256').update(await readFile(asset)).digest('hex').slice(0, 10));
      }
      url.searchParams.set('v', hashes.get(asset));
      const pathname = reference.split(/[?#]/, 1)[0];
      const stamped = `${pathname}?${url.searchParams.toString()}${url.hash}`.replace(/&/g, '&amp;');
      const newTag = tag[0].replace(match[0], () => match[0].replace(match[2], () => stamped));
      result = result.slice(0, tag.index) + newTag + result.slice(tag.index + tag[0].length);
      references.add(stamped);
    }
    if (result !== source) updates.push([filename, result]);
  }
  // Validate every reference before writing any page, so a missing file cannot
  // leave the site with a partly updated set of hashes.
  for (const [filename, source] of updates) await writeFile(filename, source);
  return [...references].sort();
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    console.log((await stampAssets(process.argv[2])).join('\n'));
  } catch (error) {
    console.error(`Asset stamping failed: ${error.message}`);
    process.exitCode = 1;
  }
}
