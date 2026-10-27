<#
.SYNOPSIS
  Prepara o OpenAI Whisper local (modelo large-v3) no Windows, em um ambiente virtual isolado.

.DESCRIPTION
  Fonte oficial: https://github.com/openai/whisper
  - Verifica FFmpeg/ffprobe, Python 3.10 ou 3.11 (o README do Whisper cobre 3.8 a 3.11) e uma instalacao existente.
  - Cria (ou reaproveita) um venv em <InstallDir>\venv. Nada e instalado no Python global.
  - Instala torch (GPU NVIDIA se houver 10 GiB de VRAM ou mais; senao CPU) e openai-whisper.
  - Baixa e carrega o modelo large-v3 com whisper.load_model("large-v3").
  - Faz um teste curto em portugues e normaliza o JSON para o formato do kit.
  O modelo e fixo em large-v3. O script nunca troca por small, turbo ou outro: se faltar
  memoria, ele para e explica. Nenhum audio e enviado para a internet; so os pesos do
  modelo sao baixados (CDN oficial da OpenAI).

.PARAMETER InstallDir
  Pasta das ferramentas (venv, pesos e teste). Use um caminho sem acentos nem espacos.

.PARAMETER Audio
  Audio ou video curto em portugues para o teste. Sem ele, o script sintetiza uma frase
  com uma voz do Windows em portugues, se existir.

.PARAMETER SkipTest
  Instala e verifica, mas nao roda o teste de transcricao.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup-whisper-windows.ps1
  powershell -ExecutionPolicy Bypass -File scripts\setup-whisper-windows.ps1 -Audio "D:\gravacoes\teste.mp4"
#>
[CmdletBinding()]
param(
  [string]$InstallDir = 'D:\ferramentas-ia\whisper',
  [string]$Audio,
  [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
$Model = 'large-v3'   # fixo de proposito: nao trocar sem consultar a pessoa
$MinVramMiB = 9800    # README do Whisper: large pede cerca de 10 GB de VRAM
$MinCpuRamGiB = 16    # CPU em FP32: ~6 GiB de pesos mais folga para carregar

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

function Write-Step([string]$Text) { Write-Host "`n== $Text ==" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  OK     $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  AVISO  $Text" -ForegroundColor Yellow }
function Stop-Setup([string]$Text) { Write-Host "`n  PARADO  $Text" -ForegroundColor Red; exit 1 }

function Invoke-Native([string]$File, [string[]]$Arguments) {
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Falhou (codigo $LASTEXITCODE): $File $($Arguments -join ' ')" }
}

# Roda um comando cujo erro e esperado (ex.: um import que pode falhar) sem abortar o script.
# No Windows PowerShell 5.1, stderr de programas nativos pode virar erro terminante com 'Stop'.
function Invoke-Quiet([string]$File, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& $File @Arguments 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
  } catch {
    return [pscustomobject]@{ Code = -1; Output = @() }
  } finally {
    $ErrorActionPreference = $previous
  }
}

# Se o disco pedido nao existe, usa a pasta do usuario em vez de falhar no meio.
$drive = Split-Path -Qualifier $InstallDir -ErrorAction SilentlyContinue
if ($drive -and -not (Test-Path -LiteralPath "$drive\")) {
  $InstallDir = Join-Path $env:USERPROFILE 'ferramentas-ia\whisper'
  Write-Host "  AVISO  O disco $drive nao existe; usando $InstallDir" -ForegroundColor Yellow
}

$KitRoot = Split-Path -Parent $PSScriptRoot
$CheckScript = Join-Path $KitRoot 'scripts\whisper-check.py'
$Normalizer = Join-Path $KitRoot 'scripts\normalize-whisper.mjs'
foreach ($required in $CheckScript, $Normalizer) {
  if (-not (Test-Path -LiteralPath $required)) { Stop-Setup "Arquivo do kit nao encontrado: $required. Rode este script de dentro de uma copia atualizada do kit." }
}

# ---------------------------------------------------------------- 1. FFmpeg
Write-Step '1/7  FFmpeg e ffprobe'
foreach ($tool in 'ffmpeg', 'ffprobe') {
  $cmd = Get-Command $tool -ErrorAction SilentlyContinue
  if (-not $cmd) { Stop-Setup "$tool nao esta no PATH. Instale com: winget install Gyan.FFmpeg  (e reabra o PowerShell)." }
  $versionLine = [string](Invoke-Quiet $cmd.Source @('-version')).Output[0]
  Write-Ok "$tool em $($cmd.Source) | $versionLine"
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Stop-Setup 'Node.js nao encontrado (o kit precisa dele para normalizar o JSON). Instale com: winget install OpenJS.NodeJS.LTS' }

# ---------------------------------------------------------------- 2. Python
Write-Step '2/7  Python compativel (3.10 ou 3.11)'
function Test-PythonCandidate([string]$Exe, [string[]]$Prefix) {
  $code = "import sys; print('%d.%d' % sys.version_info[:2]); print(sys.executable)"
  $result = Invoke-Quiet $Exe (@($Prefix) + @('-c', $code))
  if ($result.Code -ne 0 -or $result.Output.Count -lt 2) { return $null }
  try {
    $version = [version](([string]$result.Output[0]).Trim())
    if ($version -ge [version]'3.10' -and $version -le [version]'3.11') { return ([string]$result.Output[1]).Trim() }
  } catch { }
  return $null
}
function Find-Python {
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    foreach ($v in '-3.11', '-3.10') {
      $found = Test-PythonCandidate $py.Source @($v)
      if ($found) { return $found }
    }
  }
  foreach ($name in 'python', 'python3') {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      $found = Test-PythonCandidate $cmd.Source @()
      if ($found) { return $found }
    }
  }
  return $null
}

$VenvDir = Join-Path $InstallDir 'venv'
$VenvPy = Join-Path $VenvDir 'Scripts\python.exe'
$venvReady = $false
if (Test-Path -LiteralPath $VenvPy) {
  $probe = Invoke-Quiet $VenvPy @('-c', 'import whisper, torch')
  if ($probe.Code -eq 0) { $venvReady = $true }
}

$PythonExe = $null
if ($venvReady) {
  Write-Ok "Ambiente isolado existente funciona (whisper e torch importam): $VenvDir. Reutilizando."
} else {
  $PythonExe = Find-Python
  if (-not $PythonExe) {
    Write-Note 'Nenhum Python 3.10/3.11 encontrado (versoes mais novas nao sao cobertas pelo README do Whisper).'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Write-Host '  Instalando Python 3.11 com winget...'
      & winget install -e --id Python.Python.3.11 --accept-package-agreements --accept-source-agreements
      $PythonExe = Find-Python
    }
    if (-not $PythonExe) { Stop-Setup 'Python 3.11 instalado, mas ainda nao localizado. Feche e reabra o PowerShell e rode este script de novo.' }
  }
  Write-Ok "Python: $PythonExe"
}

$globalWhisper = Get-Command whisper -ErrorAction SilentlyContinue
if ($globalWhisper -and ($globalWhisper.Source -notlike "$InstallDir*")) {
  Write-Note "Ja existe um whisper fora do ambiente isolado ($($globalWhisper.Source)). Ele nao sera alterado nem usado."
}

# ---------------------------------------------------------------- 3. Recursos e dispositivo
Write-Step '3/7  Memoria e dispositivo'
$ramGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Ok "RAM total: $ramGiB GiB"
$gpuName = $null; $vramMiB = 0; $cudaVer = $null
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
  $query = Invoke-Quiet $smi.Source @('--query-gpu=name,memory.total', '--format=csv,noheader,nounits')
  if ($query.Code -eq 0 -and $query.Output.Count -gt 0) {
    $parts = ([string]$query.Output[0]) -split ','
    $gpuName = $parts[0].Trim(); $vramMiB = [int]($parts[1].Trim())
    # A versao de CUDA so escolhe qual pacote do torch baixar; ela nao decide o dispositivo.
    $banner = ''
    try { $banner = (& $smi.Source 2>$null | Out-String) } catch { }
    if ($banner -match 'CUDA Version:\s*(\d+)\.(\d+)') { $cudaVer = [version]"$($Matches[1]).$($Matches[2])" }
  }
}
$device = 'cpu'
if ($gpuName) {
  $cudaText = if ($cudaVer) { "$cudaVer" } else { 'nao identificada (usarei o pacote cu128 e confirmo depois)' }
  Write-Ok "GPU NVIDIA: $gpuName | VRAM $vramMiB MiB | CUDA do driver: $cudaText"
  if ($vramMiB -ge $MinVramMiB) {
    $device = 'cuda'
  } else {
    Write-Note "O $Model pede cerca de 10 GiB de VRAM e esta GPU tem $vramMiB MiB. Vou usar a CPU (FP32), sem trocar de modelo."
  }
} else {
  Write-Note 'Nenhuma GPU NVIDIA detectada (o PyTorch para Windows so acelera com NVIDIA). Vou usar a CPU (FP32).'
}
$torchIndex = 'https://download.pytorch.org/whl/cpu'
if ($device -eq 'cuda') {
  if (-not $cudaVer -or $cudaVer -ge [version]'12.8') { $torchIndex = 'https://download.pytorch.org/whl/cu128' }
  elseif ($cudaVer -ge [version]'12.6') { $torchIndex = 'https://download.pytorch.org/whl/cu126' }
  else { $torchIndex = 'https://download.pytorch.org/whl/cu118' }
}
Write-Ok "Dispositivo planejado: $device"

# ---------------------------------------------------------------- 4. Ambiente isolado
Write-Step '4/7  Ambiente isolado e pacotes'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
if (-not $venvReady) {
  if (-not (Test-Path -LiteralPath $VenvPy)) { Invoke-Native $PythonExe @('-m', 'venv', $VenvDir) }
  Invoke-Native $VenvPy @('-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel')
  Write-Host "  Instalando torch ($torchIndex)..."
  Invoke-Native $VenvPy @('-m', 'pip', 'install', 'torch', '--index-url', $torchIndex)
  Write-Host '  Instalando openai-whisper (PyPI, fonte oficial)...'
  Invoke-Native $VenvPy @('-m', 'pip', 'install', '-U', 'openai-whisper')
  Write-Ok 'Pacotes instalados.'
}
if ($device -eq 'cuda') {
  $cudaProbe = Invoke-Quiet $VenvPy @('-c', 'import torch; print(torch.cuda.is_available())')
  if ($cudaProbe.Code -ne 0 -or (($cudaProbe.Output | Out-String).Trim() -ne 'True')) {
    Write-Note "O torch deste ambiente nao enxerga a GPU. Usando a CPU (FP32). Para tentar a GPU, apague a pasta $VenvDir e rode este script de novo."
    $device = 'cpu'
  }
}
if ($device -eq 'cpu' -and $ramGiB -lt $MinCpuRamGiB) {
  Stop-Setup "Em CPU o $Model (FP32) pede cerca de $MinCpuRamGiB GiB de RAM e este PC tem $ramGiB GiB. Nao vou trocar de modelo sozinho: me diga como prefere seguir."
}

# ---------------------------------------------------------------- 5. Pesos
Write-Step "5/7  Verificacao e download explicito do modelo $Model"
$cacheDir = Join-Path $env:USERPROFILE '.cache\whisper'
$ModelDir = Join-Path $InstallDir 'models'
if (Test-Path -LiteralPath (Join-Path $cacheDir "$Model.pt")) {
  $ModelDir = $cacheDir
  Write-Ok "Pesos ja existentes em $cacheDir. Reutilizando."
}
Invoke-Native $VenvPy @($CheckScript, '--device', $device, '--model-dir', $ModelDir)

# Configuracao para o script de transcricao reaproveitar.
$config = [ordered]@{ model = $Model; device = $device; venv = $VenvDir; modelDir = $ModelDir; kitRoot = $KitRoot }
$ConfigPath = Join-Path $InstallDir 'whisper-config.json'
$config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Ok "Configuracao salva em $ConfigPath"

# ---------------------------------------------------------------- 6. Teste
if ($SkipTest) {
  Write-Step '6/7  Teste (pulado com -SkipTest)'
  Write-Host "`nPronto. Para transcrever: scripts\whisper-transcribe-windows.ps1 -Media <arquivo>"
  exit 0
}
Write-Step '6/7  Teste curto em portugues'
$TestDir = Join-Path $InstallDir 'teste'
$OutDir = Join-Path $TestDir 'saida'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$TestAudio = $null
if ($Audio) {
  if (-not (Test-Path -LiteralPath $Audio)) { Stop-Setup "Audio do teste nao encontrado: $Audio" }
  $TestAudio = (Resolve-Path -LiteralPath $Audio).Path
} else {
  try {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voice = $synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'pt*' } | Select-Object -First 1
    if ($voice) {
      $wav = Join-Path $TestDir 'amostra-pt.wav'
      $synth.SelectVoice($voice.VoiceInfo.Name)
      $synth.SetOutputToWaveFile($wav)
      $synth.Speak('Olá, este é um teste curto de transcrição em português com o Whisper.')
      $synth.SetOutputToNull()
      $TestAudio = $wav
      Write-Ok "Amostra sintetizada localmente com a voz '$($voice.VoiceInfo.Name)'."
    }
    $synth.Dispose()
  } catch {
    Write-Note "Nao consegui sintetizar a amostra: $($_.Exception.Message)"
  }
}
if (-not $TestAudio) {
  Write-Note 'Sem voz do Windows em portugues. A instalacao esta pronta; rode o teste com um audio seu:'
  Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\setup-whisper-windows.ps1 -Audio `"caminho\do\audio.mp3`""
  exit 0
}

$WhisperExe = Join-Path $VenvDir 'Scripts\whisper.exe'
$WhisperArgs = @(
  $TestAudio, '--model', $Model, '--model_dir', $ModelDir, '--device', $device,
  '--language', 'Portuguese', '--task', 'transcribe',
  '--word_timestamps', 'True', '--output_format', 'all', '--output_dir', $OutDir
)
if ($device -eq 'cpu') { $WhisperArgs += @('--fp16', 'False') }
Invoke-Native $WhisperExe $WhisperArgs

$stem = [IO.Path]::GetFileNameWithoutExtension($TestAudio)
$whisperJson = Join-Path $OutDir "$stem.json"
foreach ($ext in 'txt', 'json', 'srt') {
  $file = Join-Path $OutDir "$stem.$ext"
  if (-not (Test-Path -LiteralPath $file)) { Stop-Setup "O Whisper nao gerou $file" }
}

# ---------------------------------------------------------------- 7. Normalizacao
Write-Step '7/7  Normalizacao para o formato do kit'
Invoke-Native 'node' @($Normalizer, $whisperJson, '--audio', $TestAudio)
$kitJson = Join-Path $OutDir "$stem.kit.json"
$kit = Get-Content -LiteralPath $kitJson -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "`n  Texto: $($kit.text)"
Write-Host "  Duracao do audio: $($kit.audio_duration_secs)s | palavras com tempo: $($kit.words.Count)"
$kit.words | Select-Object -First 8 | Format-Table text, start, end -AutoSize

Write-Host "`nPronto. Arquivos do teste em: $OutDir" -ForegroundColor Green
Get-ChildItem -LiteralPath $OutDir | Format-Table Name, Length -AutoSize
Write-Host 'Para transcrever uma gravacao sua:'
Write-Host '  powershell -ExecutionPolicy Bypass -File scripts\whisper-transcribe-windows.ps1 -Media "caminho\do\video.mp4"'
