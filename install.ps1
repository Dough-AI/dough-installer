# Dough setup for Windows - one command, from nothing to a working install.
#   irm https://raw.githubusercontent.com/Dough-AI/dough-installer/main/install.ps1 | iex
#
# In order: Python, Git for Windows, the `dough` CLI, the observability hooks,
# the Claude Code plugin, the Git Bash path Claude Code needs, and sign-in. Safe
# to re-run: every step is check-then-act, so re-running is also how you update
# the CLI and the plugin.
#
# Env overrides:
#   DOUGH_REPO        release repo (default: Dough-AI/dough-installer)
#   DOUGH_SKIP_LOGIN  set to 1 to leave `dough login` to the user
$ErrorActionPreference = "Stop"

# Make native-command failures behave the same on Windows PowerShell 5.1 and
# PowerShell 7.4+. In 7.4+ this defaults to $true, which turns any nonzero exit
# code into a thrown error under `$ErrorActionPreference = "Stop"` - so the same
# script would report winget/dough failures through a raw .NET message on one
# host and through our own guidance on the other. Every external call below
# checks $LASTEXITCODE explicitly, so opt out and keep one behaviour.
$PSNativeCommandUseErrorActionPreference = $false

$DoughRepo    = if ($env:DOUGH_REPO) { $env:DOUGH_REPO } else { "Dough-AI/dough-installer" }
$InstallerUrl = "https://raw.githubusercontent.com/$DoughRepo/main/install.ps1"

# Winget package ids. Python must be a 3.x: the Claude Code hooks this script
# registers are Python, and the CLI writes `python` (not `python3`) into them.
$PythonWingetId = "Python.Python.3.13"
$GitWingetId    = "Git.Git"

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Good { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Note { param([string]$Message) Write-Host "    $Message" }

# Builds the message thrown to the top-level handler. Every failure says what
# broke AND how to fix it, because this script stops at the first unmet
# dependency rather than limping on into a half-configured machine.
function Format-SetupError {
  param([string]$Problem, [string[]]$Fix = @())
  $lines = @($Problem)
  if ($Fix.Count) {
    $lines += ""
    $lines += "To fix this:"
    $lines += ($Fix | ForEach-Object { "  $_" })
  }
  return ($lines -join [Environment]::NewLine)
}

# Returns what $env:Path should be after an installer has run. winget writes its
# PATH changes to the registry; an already-running process keeps its own copy,
# which is why "you might have to restart PowerShell" is the usual advice.
# Assigning this result is what makes a just-installed python/git visible in THIS
# session instead.
#
# Registry entries first, then whatever the session already had, de-duplicated:
# returning the registry value alone would discard the process-only entry this
# script adds for dough.exe.
function Get-RefreshedPath {
  $fromRegistry = @(
    [Environment]::GetEnvironmentVariable("Path", "Machine")
    [Environment]::GetEnvironmentVariable("Path", "User")
  ) | Where-Object { $_ } | ForEach-Object { $_ -split ";" }

  $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
  $merged = New-Object -TypeName 'System.Collections.Generic.List[string]'
  foreach ($entry in (@($fromRegistry) + @($env:Path -split ";"))) {
    $trimmed = "$entry".Trim()
    if ($trimmed -and $seen.Add($trimmed)) { [void]$merged.Add($trimmed) }
  }
  return ($merged -join ";")
}

# 'python --version' is NOT a sufficient probe on Windows. Every install carries
# an App Execution Alias at %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe that
# is on PATH by default and is a Microsoft Store stub: on a machine with no
# Python it prints a "not found" notice and exits 9009, and Get-Command finds it
# either way. So require real output from a real interpreter.
#
# The probe is deliberately about 'python' specifically, not "some Python": the
# hooks the CLI registers in ~/.claude/settings.json run the literal command
# 'python', so a machine where only 'py -3' works has dead hooks.
function Test-PythonReady {
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) { return $false }
  try {
    $out = & python -c "import sys; print(sys.version_info.major)" 2>$null
    return ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq "3")
  } catch {
    return $false
  }
}

# Locates Git for Windows' bash.exe, or $null.
#
# The Claude Code desktop app refuses to run local sessions without it ("Git for
# Windows is required to run local sessions"), and `git` being on PATH does not
# imply it: a git from Scoop, or a minimal build, has no bash.exe. So the Git
# requirement is expressed in terms of THIS file, not `git --version`.
#
# Preferred derivation is from git.exe itself (`<GitRoot>\cmd\git.exe` ->
# `<GitRoot>\bin\bash.exe`), so a non-default install location still resolves;
# the fixed paths are the fallback.
function Get-GitBashPath {
  $candidates = @()

  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  if ($gitCmd -and $gitCmd.Source) {
    $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCmd.Source)
    if ($gitRoot) { $candidates += (Join-Path $gitRoot "bin\bash.exe") }
  }

  # Each root is guarded BEFORE Join-Path touches it: Join-Path throws on a null
  # Path, so building this list unguarded turns a probe that should answer "no"
  # into one that raises.
  $roots = @()
  if ($env:ProgramFiles) { $roots += $env:ProgramFiles }
  if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
  if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA "Programs") }
  foreach ($root in $roots) { $candidates += (Join-Path $root "Git\bin\bash.exe") }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

function Test-GitReady {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
  try {
    & git --version *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
  } catch {
    return $false
  }
  # bash.exe, not just git: see Get-GitBashPath.
  return $null -ne (Get-GitBashPath)
}

# The Store stub above can also SHADOW a real Python install when it sits
# earlier on PATH, which turns a successful winget run into a still-failing
# probe. Detected only to make that failure legible - and evaluated at failure
# time, never up front, because on a machine with no Python at all the stub is
# always present and would otherwise be blamed for every failure.
function Get-PythonStoreStub {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and $cmd.Source -like "*\WindowsApps\*") { return $cmd.Source }
  return $null
}

# Install a dependency and verify it by RE-PROBING, not by trusting winget's
# exit code. Two reasons: winget reports a nonzero "already installed" for a
# package that is present but missing from PATH, which is a case we recover from
# rather than fail on; and the thing that matters is whether the command works
# afterwards, not whether the installer claimed success. winget's exit code is
# still carried into the error message as a diagnostic.
function Install-Dependency {
  param(
    [string]$Name,
    [string]$WingetId,
    [scriptblock]$Probe,
    [scriptblock]$Fix
  )

  Write-Step $Name
  if (& $Probe) {
    Write-Good "$Name is already available."
    return
  }

  Write-Note "Not found. Installing $WingetId via winget (this can take a few minutes)..."
  $wingetExit = $null
  try {
    & winget install -e --id $WingetId --accept-package-agreements --accept-source-agreements
    $wingetExit = "exit code $LASTEXITCODE"
  } catch {
    $wingetExit = "winget could not be run: $($_.Exception.Message)"
  }

  $env:Path = Get-RefreshedPath

  if (& $Probe) {
    Write-Good "$Name installed."
    return
  }

  throw (Format-SetupError "$Name is still not usable after installing $WingetId ($wingetExit)." (& $Fix))
}

# Reads the dispatcher path back out of the hook the CLI registered. Mirrors the
# CLI's own parse of the same command string, which embeds the path as p=r'...'.
function Get-RegisteredDispatcherPath {
  # Not $HOME: that is a read-only automatic variable, and Node's homedir() -
  # which is what the CLI used to write this file - resolves to USERPROFILE.
  $profileDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  $settingsPath = Join-Path $profileDir ".claude\settings.json"
  if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }

  try {
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $settings.hooks) { return $null }

  foreach ($hookEvent in $settings.hooks.PSObject.Properties) {
    foreach ($matcher in @($hookEvent.Value)) {
      foreach ($hook in @($matcher.hooks)) {
        $command = "$($hook.command)"
        if ($command -like "*dough_trace.py*" -and $command -match "p=r'([^']*)'") {
          return $Matches[1]
        }
      }
    }
  }
  return $null
}

function Get-ClaudeSettingsPath {
  $profileDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
  return (Join-Path $profileDir ".claude\settings.json")
}

# Sets settings.env.<Name> = <Value> in ~/.claude/settings.json, preserving
# everything else. Returns "set" or "current".
#
# This rewrites the same file that holds the hooks registered a step earlier, so
# it is written defensively: back up, write, then RE-READ and confirm both the
# new value AND the pre-existing dough hook survived; restore the backup and
# throw if either did not.
#
# The specific hazard is ConvertTo-Json's default -Depth of 2. The hooks block is
# five levels deep (hooks > event > matcher > hooks > command), so a round-trip
# at the default depth silently replaces it with type names and would destroy
# observability on every machine this runs on.
function Set-ClaudeEnvSetting {
  param([string]$Name, [string]$Value)

  $settingsPath = Get-ClaudeSettingsPath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null

  $settings = $null
  if (Test-Path -LiteralPath $settingsPath) {
    $raw = Get-Content -Raw -LiteralPath $settingsPath
    if ("$raw".Trim()) {
      try {
        $settings = $raw | ConvertFrom-Json
      } catch {
        throw (Format-SetupError `
          "$settingsPath exists but is not valid JSON, so it cannot be updated safely." `
          @(
            "Fix or remove that file, then re-run:",
            "  irm $InstallerUrl | iex"
          ))
      }
    }
  }
  if ($null -eq $settings) { $settings = [pscustomobject]@{} }

  if ($settings.env -and $settings.env.$Name -eq $Value) { return "current" }

  $hookBefore = Get-RegisteredDispatcherPath

  if (-not $settings.PSObject.Properties['env'] -or $null -eq $settings.env) {
    $settings | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  if ($settings.env.PSObject.Properties[$Name]) {
    $settings.env.$Name = $Value
  } else {
    $settings.env | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }

  $backup = $null
  if (Test-Path -LiteralPath $settingsPath) {
    $backup = "$settingsPath.dough-backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
  }

  # -Depth 100: see the note above. Never lower this.
  Set-Content -LiteralPath $settingsPath -Value ($settings | ConvertTo-Json -Depth 100)

  # Verify the OUTCOME, not the write. Both halves matter: the value we came to
  # set, and the hook we must not have destroyed getting there.
  $failure = $null
  try {
    $after = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    if ($after.env.$Name -ne $Value) { $failure = "$Name was not saved" }
    elseif ($hookBefore -and (Get-RegisteredDispatcherPath) -ne $hookBefore) {
      $failure = "the Dough hook registration did not survive the write"
    }
  } catch {
    $failure = "the file is no longer valid JSON"
  }

  if ($failure) {
    if ($backup) { Copy-Item -LiteralPath $backup -Destination $settingsPath -Force }
    throw (Format-SetupError `
      "Updating $settingsPath failed: $failure." `
      @(
        "Your previous settings have been restored$(if ($backup) { " (backup kept at $backup)" }).",
        "Set it by hand instead - add this to $settingsPath :",
        "  `"env`": { `"$Name`": `"$($Value -replace '\\','\\')`" }"
      ))
  }

  if ($backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  return "set"
}

function Invoke-DoughSetup {
  Write-Host ""
  Write-Host "Dough setup for Windows" -ForegroundColor White
  Write-Host "Installing Python, Git, the dough CLI, the Claude Code plugin, and signing you in."

  # --- 0. winget ------------------------------------------------------------
  # Everything below depends on it, so an absent winget is worth failing on
  # before anything has been written to the machine.
  Write-Step "Checking prerequisites"
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw (Format-SetupError `
      "winget (the Windows Package Manager) is not available, so Python and Git cannot be installed automatically." `
      @(
        "Install 'App Installer' from the Microsoft Store, then re-run this command:",
        "  https://apps.microsoft.com/detail/9NBLGGH4NNS1",
        "",
        "Or install both dependencies by hand and re-run:",
        "  Python 3  https://www.python.org/downloads/windows/  (tick 'Add python.exe to PATH')",
        "  Git       https://git-scm.com/download/win"
      ))
  }
  Write-Good "winget is available."

  # --- 1. Python ------------------------------------------------------------
  # Claude Code runs the Dough hooks with 'python'. Without it every session
  # fires a broken hook, which surfaces later as confusing tool failures rather
  # than as a missing dependency - so it is a hard requirement here.
  Install-Dependency -Name "Python 3" -WingetId $PythonWingetId -Probe ${function:Test-PythonReady} -Fix {
    $lines = @()
    $stub = Get-PythonStoreStub
    if ($stub) {
      $lines += "A Microsoft Store placeholder is shadowing Python on your PATH:"
      $lines += "  $stub"
      $lines += ""
      $lines += "Turn it off under Settings > Apps > Advanced app settings >"
      $lines += "App execution aliases (switch OFF python.exe and python3.exe)."
    } else {
      $lines += "Install Python 3 manually, ticking 'Add python.exe to PATH':"
      $lines += "  https://www.python.org/downloads/windows/"
    }
    $lines += ""
    $lines += "Then open a new PowerShell, check that 'python --version' prints a 3.x, and re-run:"
    $lines += "  irm $InstallerUrl | iex"
    $lines
  }

  # --- 2. Git for Windows ---------------------------------------------------
  # The desktop app refuses to run local sessions without Git Bash: "Git for
  # Windows is required to run local sessions." The probe therefore requires
  # bash.exe, not just `git` on PATH - a git without it satisfies `git --version`
  # and still leaves the app blocked.
  Install-Dependency -Name "Git for Windows" -WingetId $GitWingetId -Probe ${function:Test-GitReady} -Fix {
    @(
      "Install Git for Windows - not another git build; the Claude Code desktop app",
      "needs the Git Bash that ships with it (bash.exe):",
      "  https://git-scm.com/download/win",
      "",
      "Then open a new PowerShell and re-run:",
      "  irm $InstallerUrl | iex"
    )
  }

  # --- 3. The dough CLI -----------------------------------------------------
  Write-Step "Dough CLI"
  $asset = "dough-windows-x64.exe"
  $url   = "https://github.com/$DoughRepo/releases/latest/download/$asset"
  $dir   = Join-Path $env:LOCALAPPDATA "dough\bin"
  $dest  = Join-Path $dir "dough.exe"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null

  Write-Note "Downloading $asset..."
  # Invoke-WebRequest renders a progress bar that dominates its own runtime on
  # Windows PowerShell; silencing it is worth minutes on a slow link.
  $previousProgress = $ProgressPreference
  $ProgressPreference = "SilentlyContinue"
  # Staged download: writing straight to $dest fails mid-flight if anything holds
  # a handle on the existing dough.exe, which would leave no working binary at
  # all. Download first, move second.
  $staged = Join-Path ([System.IO.Path]::GetTempPath()) "dough-$PID.exe"
  try {
    Invoke-WebRequest -Uri $url -OutFile $staged
  } finally {
    $ProgressPreference = $previousProgress
  }
  try {
    Move-Item -LiteralPath $staged -Destination $dest -Force
  } catch {
    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    throw (Format-SetupError `
      "Could not replace $dest - it is probably in use." `
      @(
        "Close Claude Code and any terminal running dough, then re-run:",
        "  irm $InstallerUrl | iex"
      ))
  }

  # Persist the install dir on the user PATH (applies to future terminals)...
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { $userPath = "" }
  if ($userPath -notlike "*$dir*") {
    $newPath = if ($userPath) { "$userPath;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  }
  # ...and make `dough` usable in THIS session too.
  if (";$env:Path;" -notlike "*;$dir;*") { $env:Path = "$env:Path;$dir" }
  Write-Good "Installed to $dest"

  # Prove the binary actually runs before anything downstream depends on it.
  # The release is unsigned, so SmartScreen can block the first execution - and
  # every later step (self-heal, plugin install, login) would then fail with its
  # own misleading message about hooks or plugins rather than about this.
  # `--version` is offline and needs no auth, so it isolates exactly that.
  $cliVersion = $null
  try {
    $cliVersion = (& $dest --version 2>&1) -join " "
  } catch {
    $cliVersion = $null
  }
  if ($LASTEXITCODE -ne 0 -or -not $cliVersion) {
    throw (Format-SetupError `
      "The dough CLI was downloaded but will not run." `
      @(
        "Windows may have blocked it: the binary is unsigned, so SmartScreen can",
        "stop the first run. Start it once by hand and allow it:",
        "  & '$dest' --version",
        "  (if a 'Windows protected your PC' dialog appears: More info > Run anyway)",
        "",
        "Then re-run:",
        "  irm $InstallerUrl | iex"
      ))
  }
  Write-Good "CLI reports version $($cliVersion.Trim())"

  # --- 4. Observability hooks ----------------------------------------------
  # `dough self-heal` writes ~/Dough/.dough/dough_trace.py + dough_secrets.py and
  # registers the Claude Code hooks that run them. Nothing else in this script
  # does that - `dough plugin install` does not.
  Write-Step "Claude Code hooks"
  # Keep whatever self-heal prints: it exits 0 unconditionally, so this output is
  # the only evidence of WHY it did nothing, and the checks below are the only
  # thing that notices it did.
  $selfHealOutput = $null
  try {
    $selfHealOutput = (& $dest self-heal 2>&1) -join [Environment]::NewLine
  } catch {
    $selfHealOutput = $_.Exception.Message
  }
  $selfHealDetail = if ("$selfHealOutput".Trim()) {
    @("", "'dough self-heal' said:", "  $("$selfHealOutput".Trim())")
  } else {
    @()
  }
  # self-heal catches every error internally and always exits 0, so its exit
  # code proves nothing. Assert the outcome instead: a hook registered in
  # settings.json, and the two files that hook needs actually on disk. The hook
  # is written to no-op silently when the dispatcher is missing, so an
  # unverified install would look healthy and capture nothing.
  $dispatcher = Get-RegisteredDispatcherPath
  if (-not $dispatcher) {
    throw (Format-SetupError `
      "The Dough hooks were not registered in %USERPROFILE%\.claude\settings.json." `
      (@(
        "If settings.json exists but is not valid JSON the CLI refuses to touch it;",
        "fix or remove that file, then re-run:",
        "  irm $InstallerUrl | iex"
      ) + $selfHealDetail))
  }
  $secretsLib = Join-Path (Split-Path -Parent $dispatcher) "dough_secrets.py"
  $missing = @($dispatcher, $secretsLib) | Where-Object { -not (Test-Path -LiteralPath $_) }
  if ($missing) {
    throw (Format-SetupError `
      "The Dough hooks point at files that are not on disk: $($missing -join ', ')." `
      (@(
        "Re-run and, if it happens again, report the output of:",
        "  dough self-heal",
        "",
        "  irm $InstallerUrl | iex"
      ) + $selfHealDetail))
  }
  Write-Good "Hooks registered against $dispatcher"

  # --- 5. Claude Code plugin ------------------------------------------------
  # Needs no authentication: it fetches a public tarball over HTTPS, which is
  # why it can run before login.
  Write-Step "Claude Code plugin"
  & $dest plugin install
  if ($LASTEXITCODE -ne 0) {
    throw (Format-SetupError `
      "'dough plugin install' failed (exit code $LASTEXITCODE)." `
      @(
        "Re-run it on its own to see the full error:",
        "  dough plugin install"
      ))
  }
  Write-Good "Plugin installed."

  # --- 6. Point Claude Code at Git Bash -------------------------------------
  # Without this the desktop app can open on a machine that has Git for Windows
  # and still say "Git for Windows is required to run local sessions. If it's
  # already installed, set the CLAUDE_CODE_GIT_BASH_PATH environment variable..."
  #
  # Both mechanisms are written, deliberately. settings.json is the DOCUMENTED
  # one (code.claude.com/docs/en/setup shows exactly this env block), while the
  # environment variable is the one the app's own error message names - and there
  # are open reports of the variable alone not being honoured. Neither is
  # expensive, and only the pair covers what the app actually reads.
  #
  # Runs last of the writers: `dough plugin install` also rewrites settings.json.
  # It preserves unknown keys, so order is not strictly required - but being the
  # last writer means that guarantee is not load-bearing.
  Write-Step "Git Bash for Claude Code"
  $gitBash = Get-GitBashPath
  if (-not $gitBash) {
    # Unreachable via the probe above, which already requires this file; kept so
    # a future reordering fails loudly instead of writing an empty setting.
    throw (Format-SetupError `
      "Git for Windows is installed but bash.exe could not be located." `
      @(
        "Reinstall Git for Windows and re-run:",
        "  https://git-scm.com/download/win",
        "  irm $InstallerUrl | iex"
      ))
  }

  $envResult = Set-ClaudeEnvSetting -Name "CLAUDE_CODE_GIT_BASH_PATH" -Value $gitBash
  if (([Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")) -ne $gitBash) {
    [Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $gitBash, "User")
  }
  $env:CLAUDE_CODE_GIT_BASH_PATH = $gitBash
  if ($envResult -eq "current") {
    Write-Good "Already pointing at $gitBash"
  } else {
    Write-Good "Pointed Claude Code at $gitBash"
  }

  # --- 7. Sign in -----------------------------------------------------------
  # --- Google Workspace CLI -------------------------------------------------
  # Installs the `gws` binary only. It does NOT connect anything: no `gws auth`,
  # no call to Dough, and nothing written to ~/.config/gws.
  #
  # That boundary is deliberate. Connecting means a Google consent screen, and
  # every consent permanently consumes one of the OAuth app's 100 lifetime user
  # slots - a cap that cannot be reset. Spending slots at install time would burn
  # them on people who never open a spreadsheet. Connecting belongs to the
  # gws-connect skill, at the point someone actually needs a Sheet.
  #
  # Failure here is NOT fatal: Google Workspace is an optional connector, and a
  # download problem must not take the rest of a working Dough setup with it.
  Write-Step "Google Workspace CLI"
  $gwsStatus = "skipped"
  if ($env:DOUGH_SKIP_GWS -eq "1") {
    Write-Note "Skipped (DOUGH_SKIP_GWS=1)."
  } elseif (Get-Command gws -ErrorAction SilentlyContinue) {
    $gwsStatus = "present"
    Write-Good "Already installed at $((Get-Command gws).Source)"
  } else {
    $gwsTmp = Join-Path ([System.IO.Path]::GetTempPath()) "gws-$PID"
    try {
      $gwsAsset = "google-workspace-cli-x86_64-pc-windows-msvc.zip"
      $gwsBase  = "https://github.com/googleworkspace/cli/releases/latest/download"
      $gwsDir   = Join-Path $env:LOCALAPPDATA "dough\bin"
      New-Item -ItemType Directory -Force -Path $gwsTmp | Out-Null
      New-Item -ItemType Directory -Force -Path $gwsDir | Out-Null

      $previousProgress = $ProgressPreference
      $ProgressPreference = "SilentlyContinue"
      try {
        Invoke-WebRequest -Uri "$gwsBase/$gwsAsset" -OutFile (Join-Path $gwsTmp $gwsAsset)
        Invoke-WebRequest -Uri "$gwsBase/$gwsAsset.sha256" -OutFile (Join-Path $gwsTmp "$gwsAsset.sha256")
      } finally {
        $ProgressPreference = $previousProgress
      }

      # The .sha256 names the asset; compare hashes directly rather than relying
      # on a filename match.
      $want = ((Get-Content (Join-Path $gwsTmp "$gwsAsset.sha256") -Raw).Trim() -split '\s+')[0]
      $got  = (Get-FileHash (Join-Path $gwsTmp $gwsAsset) -Algorithm SHA256).Hash
      if ($want -ne $got) { throw "checksum mismatch" }

      Expand-Archive -Path (Join-Path $gwsTmp $gwsAsset) -DestinationPath $gwsTmp -Force
      $gwsUnpacked = Get-ChildItem -Path $gwsTmp -Filter "gws.exe" -Recurse | Select-Object -First 1
      if (-not $gwsUnpacked) { throw "gws.exe not found in $gwsAsset" }

      # Prove it runs before it is put anywhere. A non-empty version, not merely a
      # zero exit - the release is unsigned, so SmartScreen can block the first
      # execution, and an empty or truncated download would otherwise pass.
      $gwsProbe = & $gwsUnpacked.FullName --version 2>$null | Select-Object -First 1
      if (-not $gwsProbe) { throw "the downloaded gws did not run" }

      Move-Item -LiteralPath $gwsUnpacked.FullName -Destination (Join-Path $gwsDir "gws.exe") -Force
      $gwsStatus = "installed"
      Write-Good "Installed $gwsProbe to $(Join-Path $gwsDir 'gws.exe')"
    } catch {
      $gwsStatus = "failed"
      Write-Note "Could not install gws ($($_.Exception.Message)). Skipping - Dough itself is unaffected."
    } finally {
      Remove-Item -LiteralPath $gwsTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Step "Sign in"
  if ($env:DOUGH_SKIP_LOGIN -eq "1") {
    Write-Note "DOUGH_SKIP_LOGIN=1 - skipping. Run 'dough login' when you're ready."
  } else {
    # `dough status` prints JSON; loggedIn tells us whether to skip. Treat any
    # unreadable answer as "not logged in" and let login sort it out.
    $loggedIn = $false
    try {
      $statusJson = (& $dest status 2>$null) -join [Environment]::NewLine
      if ($LASTEXITCODE -eq 0) {
        $loggedIn = [bool](($statusJson | ConvertFrom-Json).loggedIn)
      }
    } catch {
      $loggedIn = $false
    }

    if ($loggedIn) {
      Write-Good "Already signed in."
    } else {
      Write-Note "Opening your browser to sign in..."
      & $dest login
      if ($LASTEXITCODE -ne 0) {
        throw (Format-SetupError `
          "'dough login' did not complete (exit code $LASTEXITCODE)." `
          @(
            "Run it again and finish the sign-in in your browser:",
            "  dough login"
          ))
      }
      Write-Good "Signed in."
    }
  }

  # --- Done -----------------------------------------------------------------
  Write-Host ""
  Write-Host "Dough is set up." -ForegroundColor Green
  Write-Host ""
  Write-Host "One thing left, and it matters:" -ForegroundColor Yellow
  Write-Host "  Fully quit Claude Code and reopen it." -ForegroundColor Yellow
  Write-Host "  Closing the window is not enough - use Alt+F4, or quit it from the system tray." -ForegroundColor Yellow
  Write-Host "  Claude Code reads the plugin and hooks at startup, so a running app sees none of this."
  Write-Host ""
  if ($gwsStatus -eq "installed" -or $gwsStatus -eq "present") {
    Write-Host ""
    Write-Host "  The Google Workspace CLI (gws) is installed but not connected." -ForegroundColor Yellow
    Write-Host "  Nothing was shared with Google. To connect Sheets, Docs and Drive, ask"
    Write-Host "  Claude Code to ""connect Google Workspace"" when you need it."
  }
  Write-Host ""
}

# `exit` is not usable here: under `irm | iex` this runs in the caller's own
# session scope, so exiting would close their PowerShell window and take the
# error message with it. Fail by throwing, and report from here instead.
try {
  Invoke-DoughSetup
} catch {
  Write-Host ""
  Write-Host "Setup stopped." -ForegroundColor Red
  Write-Host ""
  Write-Host $_.Exception.Message -ForegroundColor Yellow
  Write-Host ""
  $global:LASTEXITCODE = 1
}
