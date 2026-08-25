$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$setupScript = Join-Path $projectRoot "setup-wsl.ps1"
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

Write-Output "PASS: Windows paths and the WSL Git update source are configured correctly."
