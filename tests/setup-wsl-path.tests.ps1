$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$setupScript = Join-Path $projectRoot "setup-wsl.ps1"
$cmdLauncher = Join-Path $projectRoot "setup-wsl.cmd"
$inputPath = "C:\Users\reisu\My Folder\codex-wsl-bootstrap"
$codexAppHome = "C:\Users\reisu\.codex"
$expected = "WSL_ROOT=/mnt/c/Users/reisu/My Folder/codex-wsl-bootstrap"
$expectedCodexAppHome = "CODEX_APP_HOME_WSL=/mnt/c/Users/reisu/.codex"

$result = @(& $setupScript -DryRun -SourcePath $inputPath -CodexAppHome $codexAppHome)

if (($result -join "`n") -ne (@($expected, $expectedCodexAppHome) -join "`n")) {
    throw "Unexpected conversion result: $($result -join ', ')"
}

$remoteResult = @(& $setupScript -DryRun -CodexAppHome $codexAppHome)
$expectedRemote = @(
    "WSL_GIT_REPOSITORY=https://github.com/oteme/codex-wsl-bootstrap.git",
    "WSL_GIT_REF=main",
    $expectedCodexAppHome
)

if (($remoteResult -join "`n") -ne ($expectedRemote -join "`n")) {
    throw "Unexpected remote update configuration: $($remoteResult -join ', ')"
}

$cmdContent = [System.IO.File]::ReadAllText($cmdLauncher)
if (-not $cmdContent.Contains("https://raw.githubusercontent.com/oteme/codex-wsl-bootstrap/main/setup-wsl.ps1")) {
    throw "setup-wsl.cmd does not download the latest PowerShell launcher."
}

# Every WSL command starts in the Linux home directory, whatever folder the launcher runs from.
$wslCalls = @([System.IO.File]::ReadAllLines($setupScript) |
    Where-Object { $_ -match '\bwsl\.exe\s' -and $_.TrimStart() -notlike '#*' })
if ($wslCalls.Count -lt 6) {
    throw "Expected at least 6 wsl.exe calls in setup-wsl.ps1, found $($wslCalls.Count)."
}
foreach ($call in $wslCalls) {
    if ($call -notmatch "\bwsl\.exe --cd '~' ") {
        throw "A wsl.exe call does not start in the Linux home directory: $($call.Trim())"
    }
}

Write-Output "PASS: Windows paths, the WSL Git update source and the WSL start directory are configured correctly."
