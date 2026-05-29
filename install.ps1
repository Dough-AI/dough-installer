# Dough CLI installer for Windows.
#   irm https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.ps1 | iex
#
# Env overrides:
#   DOUGH_REPO   release repo (default: Dough-AI/dough-installer)
$ErrorActionPreference = "Stop"

$repo  = if ($env:DOUGH_REPO) { $env:DOUGH_REPO } else { "Dough-AI/dough-installer" }
$asset = "dough-windows-x64.exe"
$url   = "https://github.com/$repo/releases/latest/download/$asset"

$dir  = Join-Path $env:LOCALAPPDATA "dough\bin"
$dest = Join-Path $dir "dough.exe"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host "dough: downloading $asset..."
Invoke-WebRequest -Uri $url -OutFile $dest

# Add the install dir to the user PATH if it isn't already there.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
if ($userPath -notlike "*$dir*") {
  $newPath = if ($userPath) { "$userPath;$dir" } else { $dir }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  Write-Host "dough: added $dir to your user PATH (open a new terminal to pick it up)."
}

Write-Host "dough: installed to $dest"
Write-Host ""
Write-Host "Next: dough login --url https://app.usedough.ai"
