# Usage: Right-click this file and select "Run with PowerShell" or run from PowerShell.
# It reads assets/wake/hey_teddy.ppn and writes hey_teddy_base64.txt in the project root.
$ErrorActionPreference = "Stop"

function Pause-IfConsoleHost {
  try {
    if ($Host.Name -eq 'ConsoleHost') {
      Write-Host ''
      Read-Host 'Done. Press Enter to close this window'
    }
  } catch {}
}

try {
  $ppnPath = Join-Path $PSScriptRoot "..\assets\wake\hey_teddy.ppn"
  $ppnPath = (Resolve-Path $ppnPath).Path
  $outPath = Join-Path $PSScriptRoot "..\hey_teddy_base64.txt"

  Write-Host "Input : $ppnPath"
  Write-Host "Output: $outPath"

  if (!(Test-Path $ppnPath)) {
    throw "File not found: $ppnPath. Place your hey_teddy.ppn at assets/wake/hey_teddy.ppn"
  }

  $file = Get-Item $ppnPath
  if ($file.Length -eq 0) {
    throw "File is empty (0 KB): $ppnPath. Download the real Porcupine .ppn from Picovoice and replace the placeholder."
  }

  $bytes = [System.IO.File]::ReadAllBytes($ppnPath)
  $b64 = [System.Convert]::ToBase64String($bytes)
  [System.IO.File]::WriteAllText($outPath, $b64)
  Write-Host "Success. Wrote Base64 to: $outPath"
} catch {
  Write-Error $_
} finally {
  Pause-IfConsoleHost
}
  