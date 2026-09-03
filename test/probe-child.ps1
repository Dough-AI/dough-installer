# Runs ONE probe from install.ps1 in a fresh process, so PATH is the one this
# process inherited and PowerShell's command cache is empty. Mutating $env:Path
# in an already-running session does not reliably change what Get-Command finds.
param([string]$InstallerPath, [string]$ProbeName)
$e = $null; $t = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$t, [ref]$e)
if ($e) { "PARSE-ERROR"; exit 1 }
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  Invoke-Expression $fn.Extent.Text
}
if (& $ProbeName) { "TRUE" } else { "FALSE" }
