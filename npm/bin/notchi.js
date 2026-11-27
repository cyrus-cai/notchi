#!/usr/bin/env node
// npx notchi: downloads the latest Notchi release from GitHub, installs it
// into /Applications, clears the quarantine flag and launches it.
'use strict';
const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPO = 'cyrus-cai/notchi';
const APP = 'Notchi.app';
const DEST = path.join('/Applications', APP);
const LEGACY = ['Notch.app', 'NotchGlass.app'];

const tty = process.stdout.isTTY;
const c = (code, s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : s);
const info = (s) => console.log(`${c(1, '==>')} ${s}`);
const ok = (s) => console.log(`${c(32, '✓')} ${s}`);
const die = (s) => { console.error(`${c(31, '✗')} ${s}`); process.exit(1); };

async function main() {
  if (process.platform !== 'darwin') die('Notchi is a macOS app. This installer only runs on macOS.');

  info(`Looking up the latest release of ${REPO}…`);
  // curl, not fetch: curl follows the http(s)_proxy environment variables.
  // The tag comes from the /releases/latest redirect, not the REST API, which
  // allows 60 anonymous requests an hour per IP and answers 403 past that.
  let latest;
  try { latest = execFileSync('curl', ['-fsSIL', '-o', '/dev/null', '-w', '%{url_effective}', `https://github.com/${REPO}/releases/latest`], { encoding: 'utf8' }); }
  catch { die('Could not reach GitHub.'); }
  const tag = latest.split('/tag/')[1] || '';
  if (!/^v\d/.test(tag)) die('No published release found.');
  const name = `Notchi-${tag}.zip`;
  const asset = { name, browser_download_url: `https://github.com/${REPO}/releases/download/${tag}/${name}` };
  ok(`Found ${tag}: ${name}`);

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'notchi-'));
  try {
    info('Downloading…');
    const zip = path.join(tmp, 'notchi.zip');
    try { execFileSync('curl', ['-fL', '--progress-bar', '-o', zip, asset.browser_download_url], { stdio: ['ignore', 'ignore', 'inherit'] }); }
    catch { die('Download failed.'); }

    info('Unpacking…');
    const out = path.join(tmp, 'x');
    execFileSync('ditto', ['-x', '-k', zip, out]);
    const names = [APP, ...LEGACY];
    let src = null;
    for (const top of [out, ...fs.readdirSync(out).map((n) => path.join(out, n))]) {
      for (const n of names) if (fs.existsSync(path.join(top, n))) { src = path.join(top, n); break; }
      if (src) break;
    }
    if (!src) die(`Could not find ${APP} inside the archive.`);

    if (fs.existsSync(DEST)) {
      info(`Replacing existing ${APP}…`);
      try { fs.rmSync(DEST, { recursive: true, force: true }); }
      catch { die(`Could not remove old ${DEST} (try: sudo rm -rf "${DEST}").`); }
    }
    for (const n of LEGACY) {
      const p = path.join('/Applications', n);
      if (fs.existsSync(p)) { info(`Removing legacy ${n}…`); fs.rmSync(p, { recursive: true, force: true }); }
    }

    info('Installing to /Applications…');
    try { execFileSync('ditto', [src, DEST]); }
    catch { die('Could not copy into /Applications (you may need write permission).'); }
    try { execFileSync('xattr', ['-dr', 'com.apple.quarantine', DEST]); } catch {}

    ok(`Notchi installed to ${DEST}`);
    info('Launching…');
    try { execFileSync('open', [DEST]); } catch {}
    console.log(`\n${c(1, 'Done.')} Hover your notch to wake it.`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

main().catch((e) => die(e.message || String(e)));
