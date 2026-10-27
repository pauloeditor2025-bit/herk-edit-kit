# Local OpenAI Whisper (large-v3) on Windows

Fully local transcription with [openai/whisper](https://github.com/openai/whisper).
No audio leaves the computer; only the model weights (about 3 GB, once) are
downloaded. The model is **fixed to `large-v3`**: the scripts never substitute
`small`, `turbo`, or another model. If the machine cannot run it, they stop and
explain why.

## Install

From the kit root, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-whisper-windows.ps1
```

Optional: `-InstallDir "D:\tools\whisper"` (default `D:\ferramentas-ia\whisper`; use a
path without accents or spaces) and `-Audio "short-portuguese-clip.mp3"` for the test.

The script checks FFmpeg/ffprobe, Node, and Python **3.10 or 3.11** (the Whisper
README covers 3.8 to 3.11; current PyTorch for Windows starts at 3.10). It reuses a
working venv and existing `large-v3.pt` weights, and installs only what is missing,
inside `<InstallDir>\venv`; nothing goes into the global Python.

Device choice, with no model change:

| Machine | Device |
| --- | --- |
| NVIDIA GPU with about 10 GiB of VRAM or more | CUDA (PyTorch wheels `cu118`, `cu126` or `cu128`, picked from the driver's CUDA version) |
| Smaller or no NVIDIA GPU | CPU with `--fp16 False` (FP32); needs about 16 GiB of RAM |

If neither fits, the script stops with the numbers instead of swapping models.

`scripts/whisper-check.py` verifies the import, memory, and loads the weights with
`whisper.load_model("large-v3")`, confirming the multilingual 128-mel checkpoint.

## Transcribe a recording

```powershell
powershell -ExecutionPolicy Bypass -File scripts\whisper-transcribe-windows.ps1 -Media "path\to\raw.mp4"
```

The underlying call is `whisper <media> --model large-v3 --language Portuguese --task transcribe --word_timestamps True --output_format all`.
Outputs, none overwritten without `-Force`:

- `raw.whisper\`: Whisper's own TXT, JSON, SRT, VTT, and TSV.
- `raw.json`: the transcript in the kit format.

## Kit format

`scripts/normalize-whisper.mjs` turns Whisper's JSON into the format the cutting tools
read (see [TOOLS-AND-API-KEYS.md](TOOLS-AND-API-KEYS.md)):

```json
{ "language_code": "pt", "audio_duration_secs": 12.34, "text": "...",
  "words": [{ "text": "Olá,", "start": 0.5, "end": 0.9, "type": "word" }] }
```

Times are copied exactly as Whisper wrote them. A word without numeric start/end stops
the run, and `audio_duration_secs` comes from ffprobe on the source file (or
`--duration`), never from the last word. Run it by hand with:

```sh
node scripts/normalize-whisper.mjs raw.whisper/raw.json --audio raw.mp4 --out raw.json
```

Tests: `npm test` covers the normalizer with a synthetic fixture. The PowerShell
scripts and a real large-v3 run need a Windows machine and are not part of `npm test`.
