#!/usr/bin/env node
// Validate docs/nudges.json, the feature nudge policy the app reads from
// notch.website/nudges.json (see NotchGlass/Sources/FeatureNudge.swift).
//
//   node scripts/check-nudges.mjs [path]   # exit 1 on any error
//
// The app drops an entry it cannot decode and shows nothing for it, so a typo
// here is silent in the app. Run this before `vercel deploy --prod`.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const FILE = process.argv[2] ?? join(ROOT, 'docs/nudges.json');
const SWIFT = join(ROOT, 'NotchGlass/Sources/FeatureNudge.swift');

const LANGUAGES = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'fr', 'es'];
const REQUIRES = ['gift', 'unifiedThreads'];
const NUDGE_KEYS = ['id', 'feature', 'priority', 'min_version', 'max_version', 'requires',
  'interval_hours', 'max_shows', 'reaction', 'text'];
const COPY_KEYS = ['invite', 'confirm', 'title', 'messages'];
const VERSION = /^\d+(\.\d+){0,2}$/;

// The features this source tree knows: the cases of `enum NudgeFeature`.
function knownFeatures() {
  const src = readFileSync(SWIFT, 'utf8');
  const body = src.match(/enum NudgeFeature[^{]*\{([\s\S]*?)\n\}/);
  if (!body) throw new Error('could not find `enum NudgeFeature` in FeatureNudge.swift');
  return [...body[1].matchAll(/^\s*case (\w+)/gm)].map((m) => m[1]);
}

const errors = [];
const warnings = [];
const isText = (v) => typeof v === 'string' && v.trim() !== '';
const isHours = (v) => typeof v === 'number' && v >= 0;

let policy;
try {
  policy = JSON.parse(readFileSync(FILE, 'utf8'));
} catch (e) {
  console.error(`${FILE}: ${e.message}`);
  process.exit(1);
}

const features = knownFeatures();

for (const key of ['min_gap_hours', 'grace_hours']) {
  if (key in policy && !isHours(policy[key])) errors.push(`${key}: not a number of hours`);
}
if (!Array.isArray(policy.nudges)) {
  errors.push('nudges: not an array');
} else {
  const ids = new Set();
  policy.nudges.forEach((nudge, index) => {
    const at = `nudges[${index}]${isText(nudge?.id) ? ` (${nudge.id})` : ''}`;
    const fail = (message) => errors.push(`${at}: ${message}`);
    if (typeof nudge !== 'object' || nudge === null) return fail('not an object');

    for (const key of Object.keys(nudge)) {
      if (!NUDGE_KEYS.includes(key)) fail(`unknown key "${key}"`);
    }
    if (!isText(nudge.id)) fail('id: missing');
    else if (ids.has(nudge.id)) fail('id: used twice');
    else ids.add(nudge.id);

    if (!features.includes(nudge.feature)) {
      fail(`feature: "${nudge.feature}" is not one of ${features.join(', ')}`);
    }
    if ('priority' in nudge && !Number.isInteger(nudge.priority)) fail('priority: not an integer');
    for (const key of ['min_version', 'max_version']) {
      if (key in nudge && !VERSION.test(nudge[key])) fail(`${key}: not a version`);
    }
    if ('requires' in nudge) {
      if (!Array.isArray(nudge.requires)) fail('requires: not an array');
      else for (const r of nudge.requires) {
        if (!REQUIRES.includes(r)) fail(`requires: "${r}" is not one of ${REQUIRES.join(', ')}`);
      }
    }
    if ('interval_hours' in nudge && !isHours(nudge.interval_hours)) fail('interval_hours: not a number of hours');
    if ('max_shows' in nudge && !(Number.isInteger(nudge.max_shows) && nudge.max_shows > 0)) {
      fail('max_shows: not a positive integer');
    }
    if ('reaction' in nudge && !isText(nudge.reaction)) fail('reaction: empty');

    const text = nudge.text;
    if (typeof text !== 'object' || text === null) return fail('text: missing');
    if (!text.en) fail('text.en: missing (the fallback for every other language)');
    for (const language of Object.keys(text)) {
      if (!LANGUAGES.includes(language)) fail(`text: "${language}" is not one of ${LANGUAGES.join(', ')}`);
    }
    for (const language of LANGUAGES) {
      const copy = text[language];
      if (!copy) {
        if (text.en) warnings.push(`${at}: text.${language} missing, English is shown`);
        continue;
      }
      for (const key of Object.keys(copy)) {
        if (!COPY_KEYS.includes(key)) fail(`text.${language}: unknown key "${key}"`);
      }
      for (const key of ['invite', 'confirm']) {
        if (!isText(copy[key])) fail(`text.${language}.${key}: missing`);
      }
      if ('title' in copy && !isText(copy.title)) fail(`text.${language}.title: empty`);
      if (!Array.isArray(copy.messages) || copy.messages.length === 0 || !copy.messages.every(isText)) {
        fail(`text.${language}.messages: needs at least one non-empty message`);
      } else if (text.en?.messages?.length && copy.messages.length !== text.en.messages.length) {
        fail(`text.${language}.messages: ${copy.messages.length} messages, English has ${text.en.messages.length}`);
      }
    }
  });
}

for (const w of warnings) console.warn(`warning: ${w}`);
if (errors.length) {
  for (const e of errors) console.error(`error: ${e}`);
  process.exit(1);
}
console.log(`${FILE}: ${policy.nudges.length} nudge(s) valid.`);
