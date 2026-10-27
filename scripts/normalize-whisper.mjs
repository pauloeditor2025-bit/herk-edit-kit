#!/usr/bin/env node
// Normalize an openai-whisper JSON (run with --word_timestamps True) into the
// transcript format the cutting tools expect:
//
//   { language_code, audio_duration_secs, text, words: [{ text, start, end, type }] }
//
// Times are copied as Whisper produced them (seconds). Nothing is estimated:
// a word without finite start/end, or with end < start, stops the run. The full
// recording duration comes from ffprobe on the source file (or --duration), never
// from the last word.
//
// Usage:
//   node scripts/normalize-whisper.mjs <whisper.json> --audio <source media> [--out <file>] [--language pt]
//   node scripts/normalize-whisper.mjs <whisper.json> --duration 123.456 [--out <file>]
//
// Default output: <input stem>.kit.json beside the Whisper JSON.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { basename, dirname, extname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

/**
 * Convert an openai-whisper result into the kit format.
 * Throws an Error with a readable message when timing is missing or invalid.
 * @param {object} result Parsed Whisper JSON ({ text, segments, language }).
 * @param {{ audioDurationSecs: number, languageCode?: string }} options
 * @returns {{ doc: object, warnings: string[], stats: object }}
 */
export function normalizeWhisper(result, { audioDurationSecs, languageCode } = {}) {
  if (!result || typeof result !== "object" || !Array.isArray(result.segments)) {
    throw new Error("not a Whisper JSON: the `segments` array is missing");
  }
  if (!Number.isFinite(audioDurationSecs) || audioDurationSecs <= 0) {
    throw new Error(
      "audio_duration_secs is required: pass --audio <source recording> (read with ffprobe) or --duration <seconds>",
    );
  }

  const warnings = [];
  const words = [];
  let skippedEmptyTokens = 0;
  let segmentsWithoutWords = 0;
  let outOfOrder = 0;
  let overlaps = 0;

  result.segments.forEach((segment, segmentIndex) => {
    if (!segment || typeof segment !== "object") {
      throw new Error(`segment ${segmentIndex} is not an object`);
    }
    const segmentText = typeof segment.text === "string" ? segment.text.trim() : "";
    if (!Array.isArray(segment.words)) {
      if (segmentText) {
        throw new Error(
          `segment ${segmentIndex} has no \`words\` list: run Whisper with --word_timestamps True (timing is never invented)`,
        );
      }
      return;
    }
    if (segmentText && segment.words.length === 0) {
      segmentsWithoutWords += 1;
      warnings.push(
        `segment ${segmentIndex} ("${segmentText.slice(0, 40)}") has text but no word timing; it was left out of \`words\``,
      );
      return;
    }

    segment.words.forEach((word, wordIndex) => {
      const label = `segment ${segmentIndex}, word ${wordIndex}`;
      const text = typeof word?.word === "string" ? word.word.trim() : "";
      if (!text) {
        skippedEmptyTokens += 1;
        return;
      }
      const { start, end } = word;
      if (typeof start !== "number" || typeof end !== "number" || !Number.isFinite(start) || !Number.isFinite(end)) {
        throw new Error(`${label} ("${text}") has no numeric start/end; timing is never invented`);
      }
      if (start < 0 || end < start) {
        throw new Error(`${label} ("${text}") has invalid timing (start ${start}, end ${end})`);
      }
      const previous = words.at(-1);
      if (previous) {
        if (start < previous.start) outOfOrder += 1;
        else if (start < previous.end - 0.05) overlaps += 1;
      }
      words.push({ text, start, end, type: "word" });
    });
  });

  if (words.length === 0) {
    throw new Error("no timed words found in the Whisper JSON");
  }
  if (outOfOrder > 0) {
    warnings.push(`${outOfOrder} word(s) start before the previous word starts; times were kept as Whisper wrote them`);
  }
  if (overlaps > 0) {
    warnings.push(`${overlaps} word(s) overlap the previous word by more than 0.05 s; times were kept as Whisper wrote them`);
  }
  const lastEnd = Math.max(...words.map((w) => w.end));
  if (lastEnd > audioDurationSecs + 0.5) {
    warnings.push(
      `the last word ends at ${lastEnd}s but the recording lasts ${audioDurationSecs}s; check that the Whisper JSON belongs to this file`,
    );
  }

  const text =
    typeof result.text === "string" && result.text.trim()
      ? result.text.trim()
      : words.map((w) => w.text).join(" ");
  const language = languageCode ?? (typeof result.language === "string" ? result.language : undefined);

  const doc = {
    ...(language ? { language_code: language } : {}),
    audio_duration_secs: audioDurationSecs,
    text,
    words,
  };
  return {
    doc,
    warnings,
    stats: { words: words.length, skippedEmptyTokens, segmentsWithoutWords, outOfOrder, overlaps },
  };
}

function die(message, code = 1) {
  console.error(`error: ${message}`);
  process.exit(code);
}

function parseArgs(argv) {
  const opts = { input: null, audio: null, duration: null, out: null, language: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) die(`${arg} needs a value`);
      return argv[++i];
    };
    if (arg === "--audio") opts.audio = value();
    else if (arg === "--duration") opts.duration = Number(value());
    else if (arg === "--out") opts.out = value();
    else if (arg === "--language") opts.language = value();
    else if (arg === "-h" || arg === "--help") {
      console.log(
        "usage: node scripts/normalize-whisper.mjs <whisper.json> --audio <source media> [--out <file>] [--language pt]\n" +
          "       node scripts/normalize-whisper.mjs <whisper.json> --duration <seconds> [--out <file>]",
      );
      process.exit(0);
    } else if (arg.startsWith("--")) die(`unknown option ${arg}`);
    else if (!opts.input) opts.input = arg;
    else die(`unexpected argument ${arg}`);
  }
  return opts;
}

function probeDuration(mediaPath) {
  const probe = spawnSync(
    "ffprobe",
    ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", mediaPath],
    { encoding: "utf8" },
  );
  if (probe.error) die(`could not run ffprobe (${probe.error.message}); install FFmpeg or pass --duration`);
  if (probe.status !== 0) die(`ffprobe failed on ${mediaPath}:\n${probe.stderr}`);
  const seconds = Number(String(probe.stdout).trim());
  if (!Number.isFinite(seconds) || seconds <= 0) die(`ffprobe returned no usable duration for ${mediaPath}`);
  return Number(seconds.toFixed(3));
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!opts.input) die("pass the Whisper JSON file; see --help");
  const inputPath = resolve(opts.input);
  if (!existsSync(inputPath)) die(`input not found: ${inputPath}`);

  let audioDurationSecs;
  if (opts.audio) {
    const audioPath = resolve(opts.audio);
    if (!existsSync(audioPath)) die(`audio/video not found: ${audioPath}`);
    audioDurationSecs = probeDuration(audioPath);
  } else if (opts.duration !== null) {
    audioDurationSecs = opts.duration;
  } else {
    die("pass --audio <source recording> or --duration <seconds>: the duration is never guessed");
  }

  let result;
  try {
    result = JSON.parse(readFileSync(inputPath, "utf8").replace(/^﻿/, ""));
  } catch (error) {
    die(`could not read ${inputPath} as JSON: ${error.message}`);
  }

  let normalized;
  try {
    normalized = normalizeWhisper(result, { audioDurationSecs, languageCode: opts.language ?? undefined });
  } catch (error) {
    die(error.message);
  }

  const outputPath = resolve(
    opts.out ?? join(dirname(inputPath), `${basename(inputPath, extname(inputPath))}.kit.json`),
  );
  if (outputPath === inputPath) die("the output must be a different file from the Whisper JSON");
  writeFileSync(outputPath, `${JSON.stringify(normalized.doc, null, 2)}\n`);

  for (const warning of normalized.warnings) console.warn(`warning: ${warning}`);
  const { words, skippedEmptyTokens } = normalized.stats;
  console.log(
    `ok ${words} words | ${audioDurationSecs}s audio | ${skippedEmptyTokens} empty tokens skipped | ${outputPath}`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main();
}
