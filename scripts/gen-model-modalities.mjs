#!/usr/bin/env node
// Generate the manifest's `textOnly` list — the models that CANNOT read images —
// from OpenRouter's public model catalog, the only vendor catalog that publishes
// per-model input modalities as structured data.
//
//   node scripts/gen-model-modalities.mjs          # rewrite docs/api/models.js
//   node scripts/gen-model-modalities.mjs --check  # exit 1 if the list is stale
//   node scripts/gen-model-modalities.mjs --dry    # print the block, touch nothing
//
// It only ever touches the region between the MODALITY:START / MODALITY:END
// markers in docs/api/models.js; the rest of the function is left alone.
//
// Why a BLOCKLIST and not an allowlist: the app treats an unknown id as
// vision-capable (see `Provider.modelSupportsVision`). The catalog covers ~78% of
// the ids Notch actually dials, and the misses skew new — a model too fresh to be
// listed is far more likely to be multimodal than not — so "unknown means yes"
// is right far more often than "unknown means no", which is the bug this
// replaces.
//
// Why ids are normalized rather than family-matched: modality is a per-VARIANT
// fact, not a per-family one. `z-ai/glm-5.3` is text-only while
// `z-ai/glm-5.3-flash` reads images and video. Stripping the `-flash` suffix to
// match a family would reproduce exactly the misclassification this fixes, so
// normalization only removes things that are never semantic — the vendor prefix,
// OpenRouter's `~` router marker, and a `:free`/`:nitro` routing suffix — plus it
// folds `.` to `-` so Anthropic's native `claude-sonnet-4-6` matches the
// catalog's `claude-sonnet-4.6`.

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const TARGET = join(ROOT, 'docs/api/models.js');
const CATALOG = 'https://openrouter.ai/api/v1/models';

const START = '  // MODALITY:START';
const END = '  // MODALITY:END';

/// Must stay character-for-character in step with `Provider.normalizedModelID`
/// in NotchGlass/Sources/AIService.swift — the table is keyed by its output.
function normalize(id) {
  let s = String(id).toLowerCase().replace(/^~+/, '');
  const slash = s.indexOf('/');
  if (slash >= 0) s = s.slice(slash + 1);
  const colon = s.indexOf(':');
  if (colon >= 0) s = s.slice(0, colon);
  return s.replace(/\./g, '-');
}

/// Retried because a bare ECONNRESET from this host is common enough to redden a
/// CI run for no reason. A genuine outage still fails the script rather than
/// writing a truncated list — see the empty-catalog guard.
async function fetchCatalog(attempts = 3) {
  let last;
  for (let i = 1; i <= attempts; i++) {
    try {
      const res = await fetch(CATALOG, { signal: AbortSignal.timeout(30000) });
      if (!res.ok) throw new Error(`OpenRouter catalog: HTTP ${res.status}`);
      const { data } = await res.json();
      if (!Array.isArray(data) || data.length === 0) throw new Error('catalog came back empty');
      return data;
    } catch (err) {
      last = err;
      if (i < attempts) await new Promise((r) => setTimeout(r, 1500 * i));
    }
  }
  throw last;
}

/// An id lands in the blocklist only when the catalog positively says the model
/// takes no image input. An entry with no `input_modalities` at all says nothing
/// and is skipped — silence must not be promoted into "text-only".
function textOnlyIDs(data) {
  const verdicts = new Map();
  for (const m of data) {
    const mods = m?.architecture?.input_modalities;
    if (!Array.isArray(mods) || mods.length === 0) continue;
    const key = normalize(m.id);
    const reads = mods.includes('image');
    // Two catalog rows can normalize to one key (`glm-5.2` and `glm-5.2:free`).
    // Vision wins the tie: offering an attach that gets ignored beats hiding one
    // that would have worked.
    verdicts.set(key, (verdicts.get(key) ?? false) || reads);
  }
  return [...verdicts.entries()]
    .filter(([, reads]) => !reads)
    .map(([id]) => id)
    .sort();
}

function renderBlock(ids) {
  const today = new Date().toISOString().slice(0, 10);
  const lines = ids.map((id) => `    ${JSON.stringify(id)},`).join('\n');
  return [
    START,
    '  // Models that CANNOT read images, normalized (vendor prefix, `~`, `:free`',
    '  // stripped; `.` folded to `-`). Generated from OpenRouter\'s catalog by',
    '  // scripts/gen-model-modalities.mjs — DO NOT EDIT BY HAND, rerun the script.',
    '  //',
    '  // A blocklist, because the app reads an unknown id as vision-capable. An id',
    '  // absent here is offered an image attach; one listed here never is.',
    `  //   ${ids.length} models · regenerated ${today}`,
    '  textOnly: [',
    lines,
    '  ],',
    END,
  ].join('\n');
}

/// End offset of MANIFEST's `providers: { … },` — found by brace balance, not by
/// searching for a string, because every plausible landmark in this file also
/// appears inside a comment. (It does: anchoring on the literal `effortsOverride:`
/// once spliced the block into the middle of the comment that documents it, which
/// promoted a commented-out example into live code.)
function endOfProviders(src) {
  const m = /^  providers: \{$/m.exec(src);
  if (!m) throw new Error('could not find `providers: {` in models.js');
  let depth = 0;
  for (let i = src.indexOf('{', m.index); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) {
        const comma = src.indexOf('\n', i);
        return comma < 0 ? i + 1 : comma + 1;
      }
    }
  }
  throw new Error('unbalanced braces in `providers`');
}

function splice(src, block) {
  const i = src.indexOf(START);
  const j = src.indexOf(END);
  if (i < 0 || j < 0) {
    const at = endOfProviders(src);
    return src.slice(0, at) + block + '\n' + src.slice(at);
  }
  return src.slice(0, i) + block + src.slice(j + END.length);
}

const mode = process.argv[2] ?? '';
const ids = textOnlyIDs(await fetchCatalog());
const block = renderBlock(ids);

if (mode === '--dry') {
  console.log(block);
  process.exit(0);
}

const src = readFileSync(TARGET, 'utf8');
const next = splice(src, block);

if (mode === '--check') {
  // Compare ids only — the regenerated-on date moves every run and would make
  // --check permanently red.
  const idsOf = (s) => (s.match(/^\s{4}"[^"]+",$/gm) ?? []).join('\n');
  const stale = idsOf(src.slice(src.indexOf(START), src.indexOf(END) + 1)) !== idsOf(block);
  if (stale) {
    console.error(`docs/api/models.js textOnly list is STALE (catalog now has ${ids.length} text-only models)`);
    process.exit(1);
  }
  console.log(`textOnly list is current — ${ids.length} models`);
  process.exit(0);
}

writeFileSync(TARGET, next);
console.log(`docs/api/models.js — textOnly: ${ids.length} models`);
