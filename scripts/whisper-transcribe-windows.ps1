<#
.SYNOPSIS
  Transcreve uma gravacao com o Whisper large-v3 local e gera o JSON no formato do kit.

.DESCRIPTION
  Precisa que scripts\setup-whisper-windows.ps1 ja tenha rodado (le <InstallDir>\whisper-config.json).
  Tudo roda no seu computador; nenhum audio e enviado para a internet.

  Saidas (nada e sobrescrito):
    <pasta do video>\<nome>.whisper\   TXT, JSON, SRT, VTT e TSV originais do Whisper
    <pasta do video>\<nome>.json       transcricao normalizada para o kit
                                       (text, audio_duration_secs, words com text/start/end em segundos)

.PARAMETER Media
  Video ou audio a transcrever.

.PARAMETER Language
  Idioma falado, como o Whisper espera (padrao: Portuguese).

.PARAMETER InstallDir
  Mesma pasta usada na instalacao.

.PARAMETER Device
  Usa 'cuda' (GPU) ou 'cpu' so nesta execucao, em vez do que o setup gravou. O modelo continua large-v3.
  Util para voltar para a CPU se a GPU de 8 GiB ficar sem memoria num video longo.

.PARAMETER Force
  Permite substituir um <nome>.json e uma pasta <nome>.whisper que ja existam.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\whisper-transcribe-windows.ps1 -Media "D:\Edicao com I.A\meu-video\assets\raw.mp4"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Media,
  [string]$Language = 'Portuguese',
  [string]$InstallDir = 'D:\ferramentas-ia\whisper',
  [ValidateSet('config','cuda','cpu')][string]$Device = 'config',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

function Stop-Run([string]$Text) { Write-Host "`n  PARADO  $Text" -ForegroundColor Red; exit 1 }
function Invoke-Native([string]$File, [string[]]$Arguments) {
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Falhou (codigo $LASTEXITCODE): $File $($Arguments -join ' ')" }
}

$drive = Split-Path -Qualifier $InstallDir -ErrorAction SilentlyContinue
if ($drive -and -not (Test-Path -LiteralPath "$drive\")) { $InstallDir = Join-Path $env:USERPROFILE 'ferramentas-ia\whisper' }

$ConfigPath = Join-Path $InstallDir 'whisper-config.json'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  Stop-Run "Configuracao nao encontrada em $ConfigPath. Rode primeiro: scripts\setup-whisper-windows.ps1"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$WhisperExe = Join-Path $config.venv 'Scripts\whisper.exe'
if (-not (Test-Path -LiteralPath $WhisperExe)) { Stop-Run "whisper.exe nao encontrado em $WhisperExe. Rode de novo o setup." }
if (-not (Test-Path -LiteralPath $Media)) { Stop-Run "Arquivo nao encontrado: $Media" }

$MediaPath = (Resolve-Path -LiteralPath $Media).Path
$mediaDir = Split-Path -Parent $MediaPath
$stem = [IO.Path]::GetFileNameWithoutExtension($MediaPath)
$WhisperOut = Join-Path $mediaDir "$stem.whisper"
$KitJson = Join-Path $mediaDir "$stem.json"
$Normalizer = Join-Path $config.kitRoot 'scripts\normalize-whisper.mjs'

if (-not $Force) {
  if (Test-Path -LiteralPath $KitJson) { Stop-Run "Ja existe $KitJson. Preserve o arquivo ou rode com -Force para substituir." }
  if (Test-Path -LiteralPath $WhisperOut) { Stop-Run "Ja existe $WhisperOut. Preserve a pasta ou rode com -Force para substituir." }
}
New-Item -ItemType Directory -Force -Path $WhisperOut | Out-Null

$RunDevice = if ($Device -eq 'config') { [string]$config.device } else { $Device }
Write-Host "Transcrevendo $MediaPath com $($config.model) em $RunDevice (idioma: $Language)..." -ForegroundColor Cyan
$WhisperArgs = @(
  $MediaPath, '--model', $config.model, '--model_dir', $config.modelDir, '--device', $RunDevice,
  '--language', $Language, '--task', 'transcribe',
  '--word_timestamps', 'True', '--output_format', 'all', '--output_dir', $WhisperOut
)
if ($RunDevice -eq 'cpu') { $WhisperArgs += @('--fp16', 'False') }
Invoke-Native $WhisperExe $WhisperArgs

$whisperJson = Join-Path $WhisperOut "$stem.json"
if (-not (Test-Path -LiteralPath $whisperJson)) { Stop-Run "O Whisper nao gerou $whisperJson" }

Invoke-Native 'node' @($Normalizer, $whisperJson, '--audio', $MediaPath, '--out', $KitJson)

Write-Host "`nPronto." -ForegroundColor Green
Write-Host "  Transcricao para o kit : $KitJson"
Write-Host "  Arquivos do Whisper    : $WhisperOut  (TXT, JSON, SRT, VTT, TSV)"
Write-Host "  Proximo passo no kit   : node .agents\skills\cut-silences\scripts\cut-silences.mjs `"$KitJson`" --video `"$MediaPath`""
