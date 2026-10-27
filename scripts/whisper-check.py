#!/usr/bin/env python3
"""Check a local OpenAI Whisper install and load the large-v3 weights.

The model is fixed to large-v3 on purpose. This script never falls back to a
smaller model: if the machine cannot run large-v3 it explains why and stops, so
the person can decide what to do.

Exit codes: 0 ok | 2 import or install problem | 3 not enough memory | 4 wrong weights
"""
import argparse
import json
import os
import platform
import sys
import time

MODEL = "large-v3"
GIB = 1024 ** 3
MIN_VRAM_GIB = 10      # openai/whisper README: "large" needs about 10 GB of VRAM
MIN_FREE_RAM_GIB = 12  # CPU, FP32: ~6 GiB of weights plus loading overhead


def available_ram_gib():
    """Free physical memory in GiB, or None when it cannot be read."""
    try:
        if platform.system() == "Windows":
            import ctypes

            class MemoryStatus(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            status = MemoryStatus()
            status.dwLength = ctypes.sizeof(MemoryStatus)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
            return status.ullAvailPhys / GIB
        with open("/proc/meminfo", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) * 1024 / GIB
    except Exception:  # noqa: BLE001 - best effort only
        return None
    return None


def fail(code, message):
    print(f"ERRO: {message}", file=sys.stderr)
    sys.exit(code)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", choices=["cuda", "cpu"], required=True)
    parser.add_argument("--model-dir", required=True, help="folder that holds large-v3.pt")
    parser.add_argument(
        "--allow-low-vram",
        action="store_true",
        help="try cuda even when VRAM is below ~10 GiB (same model; stops with exit 3 on out-of-memory)",
    )
    args = parser.parse_args()

    print(f"Python {platform.python_version()} em {platform.system()} {platform.machine()}")

    try:
        import torch
    except Exception as error:  # noqa: BLE001
        fail(2, f"não consegui importar torch: {error}")
    print(f"torch {torch.__version__} | CUDA disponível: {torch.cuda.is_available()}")

    try:
        import whisper
    except Exception as error:  # noqa: BLE001
        fail(2, f"não consegui importar whisper (pacote openai-whisper): {error}")
    version = getattr(whisper, "__version__", "desconhecida")
    print(f"whisper {version} | modelos conhecidos incluem {MODEL}: {MODEL in whisper.available_models()}")
    if MODEL not in whisper.available_models():
        fail(2, f"esta versão do Whisper não conhece o modelo {MODEL}; atualize com 'pip install -U openai-whisper'")

    ram = available_ram_gib()
    print(f"RAM livre: {ram:.1f} GiB" if ram is not None else "RAM livre: não foi possível medir")

    if args.device == "cuda":
        if not torch.cuda.is_available():
            fail(2, "pedi cuda, mas o torch instalado não enxerga a GPU")
        free, total = torch.cuda.mem_get_info()
        name = torch.cuda.get_device_name(0)
        print(f"GPU: {name} | VRAM {total / GIB:.1f} GiB total, {free / GIB:.1f} GiB livres")
        if total / GIB < MIN_VRAM_GIB - 0.5:
            message = (
                f"o {MODEL} pede cerca de {MIN_VRAM_GIB} GiB de VRAM e esta GPU tem {total / GIB:.1f} GiB. "
                "Use --device cpu (FP32) ou me diga se prefere outro modelo; não vou trocar sozinho."
            )
            if not args.allow_low_vram:
                fail(3, message)
            print(f"AVISO: {message}\n       Tentando mesmo assim (--allow-low-vram); se faltar memória, o erro aparece abaixo.")
    elif ram is not None and ram < MIN_FREE_RAM_GIB:
        fail(
            3,
            f"em CPU o {MODEL} (FP32) pede cerca de {MIN_FREE_RAM_GIB} GiB de RAM livre e há {ram:.1f} GiB. "
            "Feche programas e rode de novo, ou me diga se prefere outro modelo; não vou trocar sozinho.",
        )

    os.makedirs(args.model_dir, exist_ok=True)
    print(f"Baixando/carregando {MODEL} em {args.model_dir} (o primeiro download tem cerca de 3 GB)...")
    started = time.time()
    try:
        model = whisper.load_model(MODEL, device=args.device, download_root=args.model_dir)
    except torch.cuda.OutOfMemoryError:
        fail(
            3,
            f"a GPU ficou sem memória ao carregar o {MODEL}. Rode de novo com -ForceDevice cpu "
            "(mesmo modelo, FP32) ou me diga se prefere outro modelo; não vou trocar sozinho.",
        )
    elapsed = time.time() - started

    weights = os.path.join(args.model_dir, f"{MODEL}.pt")
    weights_gib = os.path.getsize(weights) / GIB if os.path.exists(weights) else None
    dims = model.dims
    parameters = sum(p.numel() for p in model.parameters())
    dtype = str(next(model.parameters()).dtype)
    print(f"Pesos: {weights} ({weights_gib:.2f} GiB)" if weights_gib else "Pesos: arquivo não encontrado no model-dir")
    print(f"Carregado em {elapsed:.0f}s | {parameters / 1e9:.2f} bilhões de parâmetros | dtype {dtype} | dispositivo {args.device}")
    print(f"Multilíngue: {model.is_multilingual} | n_mels: {dims.n_mels} | vocabulário: {dims.n_vocab}")

    # large-v3 is the 128-mel multilingual checkpoint; large-v2 and older use 80.
    if not model.is_multilingual or dims.n_mels != 128:
        fail(4, f"os pesos carregados não parecem o {MODEL} (multilíngue com 128 mels)")

    print("RESULT " + json.dumps({
        "model": MODEL,
        "whisper": version,
        "torch": torch.__version__,
        "device": args.device,
        "dtype": dtype,
        "weights": weights,
        "load_seconds": round(elapsed),
    }))


if __name__ == "__main__":
    main()
