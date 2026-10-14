# 🔄 Швидке оновлення та синхронізація словника локацій без перезбірки APK
$ErrorActionPreference = "Stop"

$rootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $rootDir

# Забезпечуємо доступність Git у PATH
if (Test-Path "C:\flutter\bin\mingit\cmd\git.exe") {
    Set-Alias -Name git -Value "C:\flutter\bin\mingit\cmd\git.exe" -Scope Global -ErrorAction SilentlyContinue
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $env:PATH = "C:\flutter\bin\mingit\cmd;" + $env:PATH
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "🗺️ СИНХРОНІЗАЦІЯ ТА АВТОПОПОВНЕННЯ СЛОВНИКА ЛОКАЦІЙ" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Запуск аналізатора каналів та геокодера
$analyzerScript = Join-Path $rootDir "frontend/scratch/analyze_channels.py"
if (-not (Test-Path $analyzerScript)) {
    Write-Error "Не знайдено скрипт аналізатора: $analyzerScript"
    exit 1
}

Write-Host "🔍 Аналіз повідомлень та геокодування нових точок через Nominatim..." -ForegroundColor Yellow
python $analyzerScript
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Скрипт аналізатора повернув код $LASTEXITCODE"
}

# 2. Синхронізація кореневого remote_config.json із backend/remote_config.json
$backendConfig = Join-Path $rootDir "backend/remote_config.json"
$rootConfig = Join-Path $rootDir "remote_config.json"

if (Test-Path $backendConfig) {
    Copy-Item $backendConfig $rootConfig -Force
    Write-Host "✅ Синхронізовано $backendConfig -> $rootConfig" -ForegroundColor Green
}

# 3. Перевірка змін у Git та автокоміт
$gitStatus = (& git status --porcelain $rootConfig $backendConfig)
if ($gitStatus) {
    Write-Host "Знайдено оновлення у словнику локацій. Комітимо..." -ForegroundColor Green
    $gitUser = & git config user.name
    if (-not $gitUser) {
        & git config user.name "yakymgo-cyber"
        & git config user.email "yakym.g.o@gmail.com"
    }
    & git add $rootConfig $backendConfig
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    & git commit -m "Auto-update dictionary: $timestamp"
    try {
        & git push origin HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Нові локації успішно опубліковано на GitHub!" -ForegroundColor Green
        } else {
            Write-Warning "⚠️ Не вдалося виконати git push (потрібна авторизація)."
        }
    } catch {
        Write-Warning "⚠️ Помилка git push: $_"
    }
} else {
    Write-Host "Словник локацій актуальний. Змін не виявлено." -ForegroundColor Green
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "СИНХРОНІЗАЦІЮ ЗАВЕРШЕНО" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan