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
