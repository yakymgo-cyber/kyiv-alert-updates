import os

script_content = '''param (
    [string]$Changelog = "Оновлення радара та бази локацій"
)

$ErrorActionPreference = "Stop"

$rootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $rootDir

# Забезпечуємо доступність Git та GitHub CLI
if (Test-Path "C:\flutter\bin\mingit\cmd\git.exe") {
    $env:PATH = "C:\flutter\bin\mingit\cmd;" + $env:PATH
    Set-Alias -Name git -Value "C:\flutter\bin\mingit\cmd\git.exe" -Scope Global -ErrorAction SilentlyContinue
}
if (Test-Path "C:\Program Files\GitHub CLI\gh.exe") {
    $env:PATH = "C:\Program Files\GitHub CLI;" + $env:PATH
    Set-Alias -Name gh -Value "C:\Program Files\GitHub CLI\gh.exe" -Scope Global -ErrorAction SilentlyContinue
}

# Встановлюємо змінну середовища для Flutter (Windows)
$env:FLUTTER_PREBUILT_ENGINE_VERSION = "af7e796e161ae0bb1ff0758c71a7105418bd9ded"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "KYIV ALERT MONITOR - СИСТЕМА ВИПУСКУ РЕЛІЗУ (PUBLISH)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Читання поточної версії з frontend/lib/main.dart
$mainDartPath = Join-Path $rootDir "frontend/lib/main.dart"
if (-not (Test-Path $mainDartPath)) {
    Write-Error "Не знайдено файл $mainDartPath"
    exit 1
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$mainDartContent = [System.IO.File]::ReadAllText($mainDartPath, [System.Text.Encoding]::UTF8)

$currentCodeMatch = [regex]::Match($mainDartContent, 'const int kCurrentVersionCode = (\\d+);')
$currentNameMatch = [regex]::Match($mainDartContent, "const String kCurrentVersionName = '([^']+)';")

if (-not $currentCodeMatch.Success) {
    Write-Error "Не вдалося знайти kCurrentVersionCode у $mainDartPath"
    exit 1
}

$oldCode = [int]$currentCodeMatch.Groups[1].Value
$newCode = $oldCode + 1

$oldName = if ($currentNameMatch.Success) { $currentNameMatch.Groups[1].Value } else { "1.0.0" }
$parts = $oldName.Split('.')
if ($parts.Length -eq 3) {
    $patch = [int]$parts[2] + 1
    $newName = "$($parts[0]).$($parts[1]).$patch"
} else {
    $newName = "1.$newCode.0"
}

Write-Host "Оновлення версії: $oldName (Build $oldCode) -> $newName (Build $newCode)" -ForegroundColor Green

# Оновлення frontend/lib/main.dart
$mainDartContent = [regex]::Replace($mainDartContent, 'const int kCurrentVersionCode = \\d+;', "const int kCurrentVersionCode = $newCode;")
$mainDartContent = [regex]::Replace($mainDartContent, "const String kCurrentVersionName = '[^']+';", "const String kCurrentVersionName = '$newName';")
[System.IO.File]::WriteAllText($mainDartPath, $mainDartContent, $utf8NoBom)

# Оновлення frontend/pubspec.yaml
$pubspecPath = Join-Path $rootDir "frontend/pubspec.yaml"
if (Test-Path $pubspecPath) {
    $pubspecContent = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.Encoding]::UTF8)
    $pubspecContent = [regex]::Replace($pubspecContent, 'version:\\s*\\d+\\.\\d+\\.\\d+\\+\\d+', "version: $newName+$newCode")
    [System.IO.File]::WriteAllText($pubspecPath, $pubspecContent, $utf8NoBom)
}

# Оновлення backend/main.py (дефолтний конфіг)
$backendMainPath = Join-Path $rootDir "backend/main.py"
if (Test-Path $backendMainPath) {
    $backendMainContent = [System.IO.File]::ReadAllText($backendMainPath, [System.Text.Encoding]::UTF8)
    $backendMainContent = [regex]::Replace($backendMainContent, '\"version_code\":\\s*\\d+,', "`\"version_code`\": $newCode,")
    $backendMainContent = [regex]::Replace($backendMainContent, '\"version_name\":\\s*\"[^\"]+\",', "`\"version_name`\": `\"$newName`\",")
    [System.IO.File]::WriteAllText($backendMainPath, $backendMainContent, $utf8NoBom)
}

# 2. Збірка релізного APK
Write-Host "`nКомпіляція релізного APK (flutter build apk --release)..." -ForegroundColor Yellow
Push-Location (Join-Path $rootDir "frontend")
try {
    flutter build apk --release
    if ($LASTEXITCODE -ne 0) {
        throw "Помилка при виконанні flutter build apk"
    }
} finally {
    Pop-Location
}

$apkPath = Join-Path $rootDir "frontend/build/app/outputs/flutter-apk/app-release.apk"
if (-not (Test-Path $apkPath)) {
    Write-Error "APK файл не знайдено за адресою $apkPath"
    exit 1
}
$apkSizeMb = [math]::Round(((Get-Item $apkPath).Length / 1MB), 1)
Write-Host "APK успішно зібрано: $apkSizeMb MB" -ForegroundColor Green

# Копіюємо також у корінь як KyivAlert_Phone.apk для швидкого доступу
$rootApkPath = Join-Path $rootDir "KyivAlert_Phone.apk"
Copy-Item -Path $apkPath -Destination $rootApkPath -Force
Write-Host "Скопійовано до $rootApkPath" -ForegroundColor Green

# 3. Визначення URL репозиторію через git config
$repoOwner = "yakymgo-cyber"
$repoName = "kyiv-alert-updates"
try {
    $remoteUrl = (& git config --get remote.origin.url).Trim()
    if ($remoteUrl -match 'github\\.com[:/]([^/]+)/([^/\\.]+)(?:\\.git)?') {
        $repoOwner = $matches[1]
        $repoName = $matches[2]
    }
} catch {
    Write-Warning "Не вдалося отримати remote.origin.url. Використовуємо дефолтний: $repoOwner/$repoName"
}

$apkDownloadUrl = "https://github.com/$repoOwner/$repoName/releases/download/v$newName/app-release.apk"
Write-Host "Сформовано URL завантаження: $apkDownloadUrl" -ForegroundColor Cyan

# 4. Оновлення backend/remote_config.json та remote_config.json у корені через python
$updateScript = Join-Path $rootDir "backend/update_remote_config.py"
if (Test-Path $updateScript) {
    python $updateScript --version-code $newCode --version-name $newName --apk-url $apkDownloadUrl --changelog $Changelog
}
Write-Host "Оновлено remote_config.json (v$newName, Build $newCode)" -ForegroundColor Green

# 5. Git коміт та пуш
Write-Host "`nФіксація змін у Git..." -ForegroundColor Yellow
$gitUser = & git config user.name
if (-not $gitUser) {
    & git config user.name "yakymgo-cyber"
    & git config user.email "yakym.g.o@gmail.com"
}
& git add .
& git commit -m "Release v${newName}: $Changelog"
try {
    & git push origin HEAD
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Зміни успішно надіслано в репозиторій!" -ForegroundColor Green
    } else {
        Write-Warning "Не вдалося виконати git push."
    }
} catch {
    Write-Warning "Помилка git push: $_"
}

# 6. Створення GitHub Release та завантаження APK
Write-Host "`nСтворення GitHub Release через gh CLI..." -ForegroundColor Yellow
if (Get-Command gh -ErrorAction SilentlyContinue) {
    try {
        & gh release create "v$newName" "$apkPath" "$rootApkPath" --title "v$newName" --notes "$Changelog"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Реліз v$newName успішно створено та опубліковано на GitHub!" -ForegroundColor Green
        } else {
            Write-Warning "gh release повернув код помилки $LASTEXITCODE."
        }
    } catch {
        Write-Warning "Помилка при створенні релізу gh: $_"
    }
} else {
    Write-Warning "GitHub CLI (gh) не знайдено. APK зібрано локально за шляхом: $apkPath"
}

Write-Host "`nВИПУСК v$newName ЗАВЕРШЕНО УСПІШНО!" -ForegroundColor Cyan
Write-Host "Релізний APK: $apkPath" -ForegroundColor Cyan
'''

with open(r'C:\Projects\kyiv-alert-app\publish.ps1', 'w', encoding='utf-8-sig') as f:
    f.write(script_content.strip())
print("Successfully regenerated publish.ps1 with UTF-8 BOM")
