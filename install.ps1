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

# Persist the install dir on the user PATH (applies to future terminals).
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
if ($userPath -notlike "*$dir*") {
  $newPath = if ($userPath) { "$userPath;$dir" } else { $dir }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

# Make `dough` usable in THIS session immediately (the persistent PATH above
# only reaches new terminals).
if (";$env:Path;" -notlike "*;$dir;*") {
  $env:Path = "$env:Path;$dir"
}

Write-Host "dough: installed to $dest"

# Refresh the on-disk observability dispatcher (~/Dough/.dough/dough_trace.py) to
# match this CLI version. The dispatcher is otherwise only refreshed by the
# SessionStart self-heal hook, which older dispatchers skip for sessions run
# outside an agent checkout — so a plain CLI upgrade would not reach them. This
# is best-effort and offline (writes local files only); never fail the install.
try { & $dest self-heal *> $null } catch { }

Write-Host "dough: ready to use now; new terminals will also have it on PATH."
Write-Host ""
Write-Host "Next: dough login"
