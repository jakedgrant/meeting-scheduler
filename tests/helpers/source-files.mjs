import { readdir, readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);

/** Reads every file under a repository-relative directory whose name ends with one of `extensions`. */
export async function sources(directory, extensions) {
  const entries = await readdir(new URL(directory, root), { recursive: true, withFileTypes: true });
  const files = entries
    .filter(entry => entry.isFile() && extensions.some(extension => entry.name.endsWith(extension)))
    .map(entry => `${entry.parentPath}/${entry.name}`);
  return Promise.all(files.map(async path => ({ path, text: await readFile(path, 'utf8') })));
}
