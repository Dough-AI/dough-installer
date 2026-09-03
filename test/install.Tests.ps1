# Exercises the pure/inspectable helpers in install.ps1 on this machine.
# Loads ONLY the function definitions (via the AST) so the installer body,
# which would try to install Python, never runs.
$ErrorActionPreference = "Stop"

$script:Failures = 0
function Check {
  param([string]$Name, [scriptblock]$Body)
  try {
    $result = & $Body
    if ($result -eq $true) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name (got: $result)" -ForegroundColor Red; $script:Failures++ }
  } catch {
    Write-Host "  FAIL  $Name (threw: $($_.Exception.Message))" -ForegroundColor Red
    $script:Failures++
  }
}

$installer = Resolve-Path "$PSScriptRoot/../install.ps1"
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors) { throw "install.ps1 does not parse" }
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  Invoke-Expression $fn.Extent.Text
}
Write-Host "Loaded functions from install.ps1" -ForegroundColor Cyan

# --- Get-RegisteredDispatcherPath -------------------------------------------
# Build settings.json exactly as the CLI writes it: the dispatcher path is
# embedded inside a python -c program as p=r'<path>'.
$fakeHome = Join-Path ([System.IO.Path]::GetTempPath()) "dough-test-$PID"
New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome ".claude") | Out-Null
$env:USERPROFILE = $fakeHome
$dispatcherPath = 'C:\Users\Test\Dough\.dough\dough_trace.py'
$hookCommand = "python -c ""import os,runpy;p=r'$dispatcherPath';os.path.exists(p) and runpy.run_path(p,run_name='__main__')"" pre"
$settingsFile = Join-Path $fakeHome ".claude\settings.json"

Write-Host "`nGet-RegisteredDispatcherPath" -ForegroundColor Cyan

@{ hooks = @{ PreToolUse = @(@{ matcher = ".*"; hooks = @(@{ type = "command"; command = $hookCommand }) }) } } |
  ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsFile
Check "extracts the dispatcher path from a real hook command" {
  (Get-RegisteredDispatcherPath) -eq $dispatcherPath
}

# The assertion that would catch a traversal/regex that matches anything.
@{ hooks = @{ PreToolUse = @(@{ matcher = ".*"; hooks = @(@{ type = "command"; command = "echo not-dough" }) }) } } |
  ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsFile
Check "returns null when settings.json has hooks but none are Dough's" {
  $null -eq (Get-RegisteredDispatcherPath)
}

'{ "permissions": { "allow": [] } }' | Set-Content -LiteralPath $settingsFile
Check "returns null when settings.json has no hooks key at all" {
  $null -eq (Get-RegisteredDispatcherPath)
}

'{ this is not json' | Set-Content -LiteralPath $settingsFile
Check "returns null (does not throw) on malformed settings.json" {
  $null -eq (Get-RegisteredDispatcherPath)
}

Remove-Item -LiteralPath $settingsFile -Force
Check "returns null when settings.json does not exist" {
  $null -eq (Get-RegisteredDispatcherPath)
}

# Multiple events, dough hook not first: the traversal must keep looking.
@{ hooks = @{
    SessionStart = @(@{ hooks = @(@{ type = "command"; command = "echo unrelated" }) })
    PostToolUse  = @(@{ matcher = ".*"; hooks = @(@{ type = "command"; command = $hookCommand }) })
} } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsFile
Check "finds the Dough hook when it is not the first entry" {
  (Get-RegisteredDispatcherPath) -eq $dispatcherPath
}

# --- Get-RefreshedPath -------------------------------------------------------
Write-Host "`nGet-RefreshedPath" -ForegroundColor Cyan

$env:Path = "/only/in/this/process"
$refreshed = Get-RefreshedPath
Check "returns a non-empty string" { -not [string]::IsNullOrWhiteSpace($refreshed) }
Check "preserves a process-only PATH entry (the dough.exe dir case)" {
  ($refreshed -split ";") -contains "/only/in/this/process"
}

$env:Path = "/dup;/dup;/other"
$deduped = (Get-RefreshedPath) -split ";"
Check "de-duplicates repeated entries" {
  ($deduped | Where-Object { $_ -eq "/dup" }).Count -eq 1
}

$env:Path = "/keep;;  ;/also"
Check "drops empty and whitespace-only entries" {
  ((Get-RefreshedPath) -split ";" | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
}

# --- Format-SetupError -------------------------------------------------------
Write-Host "`nFormat-SetupError" -ForegroundColor Cyan

Check "includes the problem and indents each fix line" {
  $msg = Format-SetupError "It broke." @("do this", "then that")
  $msg.Contains("It broke.") -and $msg.Contains("  do this") -and $msg.Contains("  then that")
}
Check "omits the 'To fix this' header when there is no remedy" {
  (Format-SetupError "It broke." @()) -eq "It broke."
}

# --- Test-PythonReady / Test-GitReady ---------------------------------------
# These must run in a CHILD process. Reassigning $env:Path in a live session does
# not reliably change what Get-Command resolves - PowerShell caches command
# lookups - so an in-process version of these checks silently probes the real
# python on this machine and passes no matter what the shim contains.
Write-Host "`nTest-PythonReady / Test-GitReady (isolated child processes)" -ForegroundColor Cyan

$pwshExe = Join-Path $PSHOME "pwsh"
$childScript = Join-Path $PSScriptRoot "probe-child.ps1"
$shimDir = Join-Path ([System.IO.Path]::GetTempPath()) "dough-shims-$PID"
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
$stub = Join-Path $shimDir "python"

function Invoke-Probe {
  param([string]$ProbeName, [string]$PathValue)
  $saved = $env:PATH
  $env:PATH = $PathValue          # the child inherits this
  try {
    $out = & $pwshExe -NoProfile -File $childScript $installer $ProbeName
  } finally {
    $env:PATH = $saved
  }
  return ("$out".Trim() -eq "TRUE")
}

function Set-PythonShim {
  param([string]$Body)
  Set-Content -LiteralPath $stub -Value "#!/bin/sh`n$Body"
  & chmod +x $stub
}

# Control: the isolation itself must work. If PATH did not take effect in the
# child, git would still be found here and this check would fail - which is the
# point of running it first.
Check "CONTROL: git is NOT found when PATH holds only the shim dir" {
  (Invoke-Probe "Test-GitReady" $shimDir) -eq $false
}
Check "CONTROL: git IS found with this machine's real PATH" {
  (Invoke-Probe "Test-GitReady" $env:PATH) -eq $true
}

# The Microsoft Store stub: on PATH, resolves, runs, but is not Python. This is
# exactly what a naive `Get-Command python` check would wave through.
Set-PythonShim "echo 'Python was not found; run without arguments to install from the Microsoft Store' >&2`nexit 9009"
Check "rejects a Store-stub-like python (resolves, exits 9009, prints nothing)" {
  (Invoke-Probe "Test-PythonReady" $shimDir) -eq $false
}

Set-PythonShim "echo 3"
Check "accepts a python that reports major version 3" {
  (Invoke-Probe "Test-PythonReady" $shimDir) -eq $true
}

Set-PythonShim "echo 2"
Check "rejects a python that reports major version 2" {
  (Invoke-Probe "Test-PythonReady" $shimDir) -eq $false
}

# Exit 0 but no output at all - the shape that a bare `python --version` check
# on a truncated/wrapped interpreter could mistake for success.
Set-PythonShim "exit 0"
Check "rejects a python that exits 0 but prints nothing" {
  (Invoke-Probe "Test-PythonReady" $shimDir) -eq $false
}

Remove-Item -Recurse -Force $shimDir, $fakeHome -ErrorAction SilentlyContinue

# --- Install-Dependency ------------------------------------------------------
# winget does not exist on this machine, which makes the failure path directly
# testable: the winget call throws, is caught, and the re-probe decides.
Write-Host "`nInstall-Dependency" -ForegroundColor Cyan

Check "returns without running winget when the probe already passes" {
  $script:FixWasEvaluated = $false
  Install-Dependency -Name "Fake" -WingetId "No.Such.Package" `
    -Probe { $true } `
    -Fix { $script:FixWasEvaluated = $true; @("should not appear") } | Out-Null
  # Lazily evaluating -Fix is what stops the Python remediation from blaming the
  # Store stub on a machine where the stub is merely present, not the cause.
  $script:FixWasEvaluated -eq $false
}

Check "throws with the -Fix lines when the probe never passes" {
  $threw = $null
  try {
    Install-Dependency -Name "Fake" -WingetId "No.Such.Package" `
      -Probe { $false } `
      -Fix { @("do the specific thing") } | Out-Null
  } catch {
    $threw = $_.Exception.Message
  }
  $null -ne $threw -and $threw.Contains("do the specific thing") -and $threw.Contains("Fake is still not usable")
}

Check "carries a winget diagnostic into the failure message" {
  $threw = $null
  try {
    Install-Dependency -Name "Fake" -WingetId "No.Such.Package" -Probe { $false } -Fix { @("x") } | Out-Null
  } catch { $threw = $_.Exception.Message }
  # Either an exit code or the "could not be run" branch, never an empty slot.
  $threw -match "exit code|could not be run"
}

Write-Host ""
if ($script:Failures -gt 0) {
  Write-Host "$($script:Failures) FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "All checks passed" -ForegroundColor Green
