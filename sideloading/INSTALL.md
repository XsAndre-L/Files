# Sideloading the Files App (Dev Build)

This guide explains how to install the self-compiled `.msixbundle` on a Windows machine without a Microsoft Store certificate.

## Prerequisites

- Windows 10/11 with **Developer Mode** enabled  
  *(Settings → Privacy & Security → For Developers → Developer Mode: On)*
- A **PowerShell session running as Administrator**  
  *(Win + X → "Terminal (Admin)" or Win + R → type `powershell` → Ctrl+Shift+Enter)*

---

## The Problem

When you build the app locally via Visual Studio, the package is signed with a **self-signed developer certificate** (`CN=Files`). Windows will refuse to install it because this certificate is not in its trusted root store — the App Installer UI shows a grayed-out "Install" button, and `Add-AppxPackage` returns:

```
error 0x800B0109: The root certificate of the signature in the app package or bundle must be trusted.
```

---

## Solution: Trust the Bundle's Certificate, Then Install

The bundle is already signed by Visual Studio. You don't need to re-sign it — you just need to **trust the certificate it's already signed with**.

### Step 1 — Open an Administrator PowerShell

Press **Win + X** → **Terminal (Admin)** (or **Windows PowerShell (Admin)**), then click **Yes** on the UAC prompt.

### Step 2 — Run the following command

Replace `<PATH_TO_BUNDLE>` with the actual path to your `.msixbundle` file:

```powershell
$bundlePath = "<PATH_TO_BUNDLE>"

# Extract the certificate embedded in the bundle
$cert = (Get-AuthenticodeSignature $bundlePath).SignerCertificate

# Trust it in LocalMachine\Root and LocalMachine\TrustedPeople
$rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
$rootStore.Open("ReadWrite")
$rootStore.Add($cert)
$rootStore.Close()

$tpStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
$tpStore.Open("ReadWrite")
$tpStore.Add($cert)
$tpStore.Close()

Write-Host "Certificate trusted: $($cert.Subject) [$($cert.Thumbprint)]"

# Install the package
Add-AppxPackage -Path $bundlePath
Write-Host "SUCCESS - Files app installed!" -ForegroundColor Green
```

### One-liner version

```powershell
$b = "D:\Dev\Tools\Files\AppPackagesFiles.App_4.1.1.0_Test\Files.App_4.1.1.0_x86_x64_arm64.msixbundle"; $c = (Get-AuthenticodeSignature $b).SignerCertificate; foreach ($s in @("Root","TrustedPeople")) { $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($s,"LocalMachine"); $st.Open("ReadWrite"); $st.Add($c); $st.Close() }; Add-AppxPackage -Path $b; Write-Host "Done!" -ForegroundColor Green
```

> **Update the path** in `$b` to match your actual bundle location before running.

---

## Why This Works

| Step | What happens |
|------|-------------|
| `Get-AuthenticodeSignature` | Reads the `CN=Files` cert already embedded in the `.msixbundle` by Visual Studio |
| `LocalMachine\Root` | Marks the cert as a trusted **root authority** — satisfies the chain of trust |
| `LocalMachine\TrustedPeople` | Marks the publisher as a trusted **sideload source** |
| `Add-AppxPackage` | Installs the package now that the cert chain validates |

---

## Build Location

After a Release build, the bundle is generated at:

```
AppPackagesFiles.App_<version>_Test\Files.App_<version>_x86_x64_arm64.msixbundle
```

To rebuild:

```
Build → Batch Build → Files (Package) → Release | Any CPU → Rebuild
```

---

## Notes

- The trusted certificate is **machine-wide** and persists across reboots.
- Each new build may generate a **new certificate** if the project's signing key changes. If installation fails again, re-run the trust + install steps above.
- This is for **local development only**. Never distribute a self-signed MSIX publicly.
