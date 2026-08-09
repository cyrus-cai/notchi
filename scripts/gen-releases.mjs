#!/usr/bin/env node
// Generate docs/releases.html's changelog from the app's own source of truth,
// WhatsNewService.swift's `bundled` array — so the website and the in-app
// "What's New" panel never drift apart.
//
//   node scripts/gen-releases.mjs          # rewrite the page in place
//   node scripts/gen-releases.mjs --check  # exit 1 if the page is stale (CI/guard)
//
// It only ever touches the region between the RELEASES:START / RELEASES:END
// markers in docs/releases.html; everything else on the page is left alone.

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SWIFT = join(ROOT, 'NotchGlass/Sources/WhatsNewService.swift');
const PAGE = join(ROOT, 'docs/releases.html');

const START = '<!-- RELEASES:START';
const END = '<!-- RELEASES:END -->';

// --- parse Swift -----------------------------------------------------------

// Pull the `bundled` literal: from `let bundled: [Entry] = [` to its matching `]`.
function extractBundled(src) {
  const m = src.match(/bundled\s*:\s*\[Entry\]\s*=\s*\[/);
  if (!m) throw new Error('could not find `bundled: [Entry] = [` in WhatsNewService.swift');
  let i = src.indexOf('[', m.index + m[0].length - 1);
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    const c = src[j];
    if (c === '[') depth++;
    else if (c === ']') { depth--; if (depth === 0) return src.slice(i + 1, j); }
  }
  throw new Error('unbalanced brackets in bundled array');
}

// Decode a Swift string literal body (between the quotes): \" \\ \n \t etc.
function decodeSwiftString(body) {
  let out = '';
  for (let i = 0; i < body.length; i++) {
    if (body[i] === '\\' && i + 1 < body.length) {
      const n = body[++i];
      out += n === 'n' ? '\n' : n === 't' ? '\t' : n; // \" \\ \( etc → the char itself
    } else {
      out += body[i];
    }
  }
  return out;
}

// All "..."-delimited string literals inside a chunk, in order, Swift-escaping aware.
function stringsIn(chunk) {
  const res = [];
  const re = /"((?:[^"\\]|\\.)*)"/g;
  let m;
  while ((m = re.exec(chunk))) res.push(decodeSwiftString(m[1]));
  return res;
}

// The labelled array after `features:` / `fixes:` up to the next label or end.
function listField(entryBody, label) {
  const re = new RegExp(label + '\\s*:\\s*\\[');
  const m = entryBody.match(re);
  if (!m) return [];
  let i = entryBody.indexOf('[', m.index + m[0].length - 1);
  let depth = 0;
  for (let j = i; j < entryBody.length; j++) {
    if (entryBody[j] === '[') depth++;
    else if (entryBody[j] === ']') { depth--; if (depth === 0) return stringsIn(entryBody.slice(i + 1, j)); }
  }
  return [];
}

// Split the bundled body into per-Entry(...) chunks (handles nested brackets).
function entryChunks(body) {
  const chunks = [];
  const re = /Entry\s*\(/g;
  let m;
  while ((m = re.exec(body))) {
    let i = body.indexOf('(', m.index + m[0].length - 1);
    let depth = 0;
    for (let j = i; j < body.length; j++) {
      if (body[j] === '(') depth++;
      else if (body[j] === ')') { depth--; if (depth === 0) { chunks.push(body.slice(i + 1, j)); re.lastIndex = j; break; } }
    }
  }
  return chunks;
}

function scalar(entryBody, key) {
  const m = entryBody.match(new RegExp(key + '\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"'));
  return m ? decodeSwiftString(m[1]) : null;
}

function parseEntries(src) {
  return entryChunks(extractBundled(src)).map((body) => ({
    version: scalar(body, 'version'),
    date: scalar(body, 'date'),
    features: listField(body, 'features'),
    improvements: listField(body, 'improvements'),
    fixes: listField(body, 'fixes'),
    others: listField(body, 'others'),
  })).filter((e) => e.version);
}

// --- render HTML -----------------------------------------------------------

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// "2026-06-23" → "Jun 23, 2026". Pass anything else through untouched.
function fmtDate(d) {
  const m = d && d.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return d || '';
  return `${MONTHS[+m[2] - 1]} ${+m[3]}, ${m[1]}`;
}

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Compare version strings descending (newest first), numeric-segment aware.
function cmpVer(a, b) {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pb[i] || 0) - (pa[i] || 0);
    if (d) return d;
  }
  return 0;
}

function renderGroup(label, key, items) {
  if (!items.length) return '';
  const lis = items.map((t) => `          <li>${esc(t)}</li>`).join('\n');
  return (
    `      <div class="rel-group">\n` +
    `        <h4 data-i18n="${key}">${label}</h4>\n` +
    `        <ul class="rel-list">\n${lis}\n        </ul>\n` +
    `      </div>\n`
  );
}

function renderEntries(entries) {
  return entries.map((e) => {
    let html = `    <div class="rel">\n`;
    html += `      <div class="rel-head">\n`;
    html += `        <span class="rel-ver">${esc(e.version)}</span>\n`;
    html += `        <span class="rel-date">${esc(fmtDate(e.date))}</span>\n`;
    html += `      </div>\n`;
    html += renderGroup('New', 'rel.new', e.features);
    html += renderGroup('Improved', 'rel.improved', e.improvements);
    html += renderGroup('Fixed', 'rel.fixed', e.fixes);
    html += renderGroup('Other', 'rel.other', e.others);
    html += `    </div>`;
    return html;
  }).join('\n');
}

// --- splice into the page --------------------------------------------------

function build() {
  const entries = parseEntries(readFileSync(SWIFT, 'utf8')).sort((a, b) => cmpVer(a.version, b.version));
  if (!entries.length) throw new Error('parsed zero releases — refusing to wipe the page');

  const page = readFileSync(PAGE, 'utf8');
  const s = page.indexOf(START);
  const e = page.indexOf(END);
  if (s === -1 || e === -1 || e < s) throw new Error('RELEASES:START / RELEASES:END markers not found in releases.html');

  const startLineEnd = page.indexOf('\n', s) + 1; // keep the START comment line
  const block =
    page.slice(0, startLineEnd) +
    renderEntries(entries) + '\n' +
    '    ' + page.slice(e);

  return { block, entries };
}

const check = process.argv.includes('--check');
const { block, entries } = build();
const current = readFileSync(PAGE, 'utf8');

if (block === current) {
  console.log(`releases.html is up to date (${entries.length} releases, newest ${entries[0].version}).`);
  process.exit(0);
}

if (check) {
  console.error('releases.html is STALE — run: node scripts/gen-releases.mjs');
  process.exit(1);
}

writeFileSync(PAGE, block);
console.log(`Wrote releases.html: ${entries.length} releases, newest ${entries[0].version}.`);
