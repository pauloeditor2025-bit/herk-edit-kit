import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { normalizeWhisper } from '../scripts/normalize-whisper.mjs';

const root = resolve(import.meta.dirname, '..');
const script = join(root, 'scripts/normalize-whisper.mjs');
const cutSilences = join(root, '.agents/skills/cut-silences/scripts/cut-silences.mjs');
function run(file, args) { return spawnSync(process.execPath, [file, ...args], { encoding: 'utf8', cwd: root }); }
function scratch() { return mkdtempSync(join(tmpdir(), 'hyperframes-kit-whisper-')); }

// SYNTHETIC fixture shaped like openai-whisper output (--word_timestamps True).
// It is test data, not a transcript of any recording.
function whisperFixture() {
  return {
    text: ' Olá, este é um teste curto. Funciona bem.',
    language: 'pt',
    segments: [
      {
        id: 0, seek: 0, start: 0.5, end: 3.1, text: ' Olá, este é um teste curto.',
        tokens: [], temperature: 0, avg_logprob: -0.2, compression_ratio: 1.1, no_speech_prob: 0.01,
        words: [
          { word: ' Olá,', start: 0.5, end: 0.9, probability: 0.98 },
          { word: ' este', start: 1.0, end: 1.3, probability: 0.97 },
          { word: ' ', start: 1.3, end: 1.3, probability: 0.5 },
          { word: ' é', start: 1.35, end: 1.5, probability: 0.9 },
          { word: ' um', start: 1.55, end: 1.7, probability: 0.95 },
          { word: ' teste', start: 1.75, end: 2.2, probability: 0.99 },
          { word: ' curto.', start: 2.25, end: 3.1, probability: 0.96 },
        ],
      },
      {
        id: 1, seek: 0, start: 4.0, end: 5.2, text: ' Funciona bem.',
        tokens: [], temperature: 0, avg_logprob: -0.3, compression_ratio: 1.0, no_speech_prob: 0.02,
        words: [
          { word: ' Funciona', start: 4.0, end: 4.6, probability: 0.97 },
          { word: ' bem.', start: 4.65, end: 5.2, probability: 0.99 },
        ],
      },
    ],
  };
}

test('Whisper words keep their exact times and gain the kit fields', () => {
  const { doc, warnings, stats } = normalizeWhisper(whisperFixture(), { audioDurationSecs: 6 });
  assert.deepEqual(Object.keys(doc), ['language_code', 'audio_duration_secs', 'text', 'words']);
  assert.equal(doc.language_code, 'pt');
  assert.equal(doc.audio_duration_secs, 6);
  assert.equal(doc.text, 'Olá, este é um teste curto. Funciona bem.');
  assert.deepEqual(doc.words.map((w) => w.text), ['Olá,', 'este', 'é', 'um', 'teste', 'curto.', 'Funciona', 'bem.']);
  assert.deepEqual(doc.words.map((w) => [w.start, w.end]), [
    [0.5, 0.9], [1.0, 1.3], [1.35, 1.5], [1.55, 1.7], [1.75, 2.2], [2.25, 3.1], [4.0, 4.6], [4.65, 5.2],
  ]);
  assert.ok(doc.words.every((w) => w.type === 'word'));
  assert.equal(stats.skippedEmptyTokens, 1);
  assert.deepEqual(warnings, []);
});

test('missing word timing is refused instead of invented', () => {
  const noWords = whisperFixture();
  delete noWords.segments[0].words;
  assert.throws(() => normalizeWhisper(noWords, { audioDurationSecs: 6 }), /--word_timestamps True/);

  const noStart = whisperFixture();
  delete noStart.segments[0].words[1].start;
  assert.throws(() => normalizeWhisper(noStart, { audioDurationSecs: 6 }), /never invented/);

  const backwards = whisperFixture();
  backwards.segments[1].words[1].end = 4.0;
  assert.throws(() => normalizeWhisper(backwards, { audioDurationSecs: 6 }), /invalid timing/);
});

test('the recording duration must be supplied, never guessed from the last word', () => {
  assert.throws(() => normalizeWhisper(whisperFixture(), {}), /audio_duration_secs is required/);
  assert.throws(() => normalizeWhisper(whisperFixture(), { audioDurationSecs: 0 }), /audio_duration_secs is required/);
});

test('a Whisper JSON from a longer or different recording is flagged', () => {
  const { warnings } = normalizeWhisper(whisperFixture(), { audioDurationSecs: 3 });
  assert.ok(warnings.some((w) => /last word ends/.test(w)));
});

test('CLI output is accepted by the silence-cutting tool', () => {
  const dir = scratch();
  const input = join(dir, 'amostra.json');
  writeFileSync(input, JSON.stringify(whisperFixture()));
  const result = run(script, [input, '--duration', '6']);
  assert.equal(result.status, 0, result.stderr);
  const doc = JSON.parse(readFileSync(join(dir, 'amostra.kit.json'), 'utf8'));
  assert.equal(doc.words.length, 8);
  assert.equal(doc.audio_duration_secs, 6);

  const out = join(dir, 'cut');
  const cut = run(cutSilences, [join(dir, 'amostra.kit.json'), '--out-dir', out]);
  assert.equal(cut.status, 0, cut.stderr);
});

test('CLI reads the duration with ffprobe and refuses to run without one', (t) => {
  const dir = scratch();
  const input = join(dir, 'amostra.json');
  writeFileSync(input, JSON.stringify(whisperFixture()));

  const missing = run(script, [input]);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /never guessed/);

  const wav = join(dir, 'silencio.wav');
  const ffmpeg = spawnSync('ffmpeg', ['-y', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono', '-t', '6', wav], { encoding: 'utf8' });
  if (ffmpeg.error || ffmpeg.status !== 0) { t.skip('ffmpeg is not available'); return; }
  const result = run(script, [input, '--audio', wav]);
  assert.equal(result.status, 0, result.stderr);
  const doc = JSON.parse(readFileSync(join(dir, 'amostra.kit.json'), 'utf8'));
  assert.ok(Math.abs(doc.audio_duration_secs - 6) < 0.05, `duration ${doc.audio_duration_secs}`);
});
