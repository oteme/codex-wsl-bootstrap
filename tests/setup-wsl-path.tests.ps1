$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$setupScript = Join-Path $projectRoot "setup-wsl.ps1"
$cmdLauncher = Join-Path $projectRoot "setup-wsl.cmd"
$inputPath = "C:\Users\reisu\My Folder\codex-wsl-bootstrap"
$expected = "WSL_ROOT=/mnt/c/Users/reisu/My Folder/codex-wsl-bootstrap"

$result = & $setupScript -DryRun -SourcePath $inputPath

if ($result -ne $expected) {
    throw "Unexpected conversion result. Expected '$expected', got '$result'."
}

$remoteResult = @(& $setupScript -DryRun)
$expectedRemote = @(
    "WSL_GIT_REPOSITORY=https://github.com/oteme/codex-wsl-bootstrap.git",
    "WSL_GIT_REF=main"
)

if (($remoteResult -join "`n") -ne ($expectedRemote -join "`n")) {
    throw "Unexpected remote update configuration: $($remoteResult -join ', ')"
}

$cmdContent = [System.IO.File]::ReadAllText($cmdLauncher)
if (-not $cmdContent.Contains("https://raw.githubusercontent.com/oteme/codex-wsl-bootstrap/main/setup-wsl.ps1")) {
    throw "setup-wsl.cmd does not download the latest PowerShell launcher."
}

Write-Output "PASS: Windows paths and the WSL Git update source are configured correctly."
