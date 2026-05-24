# Automation script to restore, compile, package, sign, and organize the Xplorer app.
# Copyright (c) Files Community / Xplorer
# Licensed under the MIT License.

$ErrorActionPreference = "Stop"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "          Xplorer Build & Package System" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host.

$repoRoot = $PSScriptRoot
if (-not $repoRoot) { $repoRoot = Get-Location }

# 1. Locate MSBuild.exe dynamically
Write-Host "[1/7] Locating MSBuild.exe..." -ForegroundColor Green
$vsPath = "C:\Program Files\Microsoft Visual Studio\2022"
if (Test-Path $vsPath) {
    $msbuildPath = Get-ChildItem -Path $vsPath -Filter "MSBuild.exe" -Recurse -ErrorAction SilentlyContinue | 
        Where-Object { $_.FullName -like "*Current\Bin\MSBuild.exe" } | 
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $msbuildPath -or -not (Test-Path $msbuildPath)) {
    $msbuildPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
}

if (-not (Test-Path $msbuildPath)) {
    Write-Error "Could not find MSBuild.exe. Please ensure Visual Studio 2022 is installed."
}
Write-Host "Found MSBuild: $msbuildPath" -ForegroundColor Gray

# 2. Download nuget.exe if missing
Write-Host "[2/7] Checking for nuget.exe..." -ForegroundColor Green
$nugetPath = Join-Path $repoRoot "nuget.exe"
if (-not (Test-Path $nugetPath)) {
    Write-Host "Downloading nuget.exe..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nugetPath
    Write-Host "Downloaded successfully." -ForegroundColor Gray
} else {
    Write-Host "nuget.exe already exists." -ForegroundColor Gray
}

# 3. Restore C++ legacy project NuGet packages
Write-Host "[3/7] Restoring legacy VCXPROJ packages..." -ForegroundColor Green
& $nugetPath restore (Join-Path $repoRoot "src\Files.App.Launcher\Files.App.Launcher.vcxproj") -SolutionDirectory $repoRoot -Verbosity quiet

# 4. Restore the main solution packages
Write-Host "[4/7] Restoring MSBuild solution..." -ForegroundColor Green
& $msbuildPath (Join-Path $repoRoot "Files.slnx") -t:Restore -p:Platform=x64 -p:Configuration=Release -v:quiet

# 5. Build C++ Launcher project
Write-Host "[5/7] Building C++ Launcher..." -ForegroundColor Green
& $msbuildPath (Join-Path $repoRoot "src\Files.App.Launcher\Files.App.Launcher.vcxproj") -t:Build -p:Platform=x64 -p:Configuration=Release -v:quiet

# 6. Generate Self-Signed PFX Certificate
Write-Host "[6/7] Generating Self-Signed PFX certificate..." -ForegroundColor Green
$certPath = Join-Path $repoRoot "FilesApp_SelfSigned.pfx"
& powershell.exe -ExecutionPolicy Bypass -File (Join-Path $repoRoot ".github\scripts\Generate-SelfCertPfx.ps1") -Destination $certPath

# 7. Build and Sign Xplorer app
Write-Host "[7/7] Building and Signing Xplorer C# Packaged app (Release x64)..." -ForegroundColor Green
$artifactsDir = Join-Path $repoRoot "artifacts"
& $msbuildPath (Join-Path $repoRoot "src\Files.App\Files.App.csproj") `
    -t:Build `
    -p:Platform=x64 `
    -p:Configuration=Release `
    -p:AppxPackageDir="$artifactsDir" `
    -p:AppxBundle=Never `
    -p:GenerateAppxPackageOnBuild=true `
    -p:UapAppxPackageBuildMode=Sideload `
    -p:AppxPackageSigningEnabled=true `
    -p:PackageCertificateKeyFile="$certPath" `
    -p:PackageCertificatePassword="" `
    -p:PackageCertificateThumbprint="" `
    -v:quiet

# 8. Organize output installer folder
Write-Host "Organizing output files into Xplorer_Installer..." -ForegroundColor Green
$installerDir = Join-Path $repoRoot "Xplorer_Installer"
if (-not (Test-Path $installerDir)) {
    New-Item -ItemType Directory -Path $installerDir | Out-Null
}

# Write install.bat dynamically from the build script
$batContent = @"
@echo off
:: Check for administrative permissions
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :admin
) else (
    echo Requesting administrative privileges...
    powershell -Command "Start-Process -FilePath '%0' -Verb RunAs"
    exit /b
)

:admin
cd /d "%~dp0"
echo ====================================================
echo             Xplorer 4.3.0.0 Installer
echo ====================================================
echo.

:: Trust the certificate
echo [1/2] Trusting developer certificate...
powershell -ExecutionPolicy Bypass -Command "Import-PfxCertificate -FilePath 'FilesApp_SelfSigned.pfx' -CertStoreLocation Cert:\LocalMachine\Root -Password (New-Object System.Security.SecureString)" >nul 2>&1
powershell -ExecutionPolicy Bypass -Command "Import-PfxCertificate -FilePath 'FilesApp_SelfSigned.pfx' -CertStoreLocation Cert:\LocalMachine\TrustedPeople -Password (New-Object System.Security.SecureString)" >nul 2>&1
echo Done!
echo.

:: Install the package
echo [2/2] Installing Xplorer app package...
powershell -ExecutionPolicy Bypass -Command "Add-AppxPackage -Path 'Files.App_4.3.0.0_x64.msix'"
if %errorLevel% == 0 (
    echo.
    echo ====================================================
    echo SUCCESS: Xplorer 4.3.0.0 installed successfully!
    echo ====================================================
) else (
    echo.
    echo ====================================================
    echo ERROR: Installation failed. Please check the logs.
    echo ====================================================
)
echo.
pause
"@

$batPath = Join-Path $installerDir "install.bat"
Set-Content -Path $batPath -Value $batContent -Encoding Ascii

# Find built MSIX package and copy it
$msixPackage = Get-ChildItem -Path $repoRoot -Filter "Files.App_4.3.0.0_x64.msix" -Recurse | Select-Object -First 1 -ExpandProperty FullName
if ($msixPackage) {
    Copy-Item -Path $msixPackage -Destination $installerDir -Force
    Copy-Item -Path $certPath -Destination $installerDir -Force
    Write-Host "Success: MSIX package, certificate, and install.bat generated inside Xplorer_Installer." -ForegroundColor Green
} else {
    Write-Warning "Could not find the built Files.App_4.3.0.0_x64.msix file to copy."
}

Write-Host.
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "SUCCESS: Xplorer has been built and organized!" -ForegroundColor Cyan
Write-Host "Go to $installerDir and double-click install.bat to install." -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
