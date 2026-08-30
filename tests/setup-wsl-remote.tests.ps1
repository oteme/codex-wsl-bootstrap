$ErrorActionPreference = "Stop"

$remoteScript = "https://raw.githubusercontent.com/oteme/codex-wsl-bootstrap/main/setup-wsl.ps1"
$downloadedScript = Join-Path $env:TEMP ("codex-wsl-bootstrap-test-" + [guid]::NewGuid().ToString() + ".ps1")

try {
    Invoke-WebRequest -UseBasicParsing -Uri $remoteScript -OutFile $downloadedScript
    $result = @(& $downloadedScript -DryRun)
    $expectedPrefix = @(
        "WSL_GIT_REPOSITORY=https://github.com/oteme/codex-wsl-bootstrap.git",
        "WSL_GIT_REF=main"
    )

    if ($result.Count -lt 2 -or ($result[0..1] -join "`n") -ne ($expectedPrefix -join "`n")) {
        throw "Unexpected downloaded launcher output: $($result -join ', ')"
    }
    if ($result.Count -gt 3 -or ($result.Count -eq 3 -and $result[2] -notmatch '^CODEX_APP_HOME_WSL=/mnt/[A-Za-z]/Users/[^/]+/\.codex$')) {
        throw "Unexpected Codex App home output: $($result -join ', ')"
    }
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $downloadedScript
}

Write-Output "PASS: GitHub launcher download and execution work in Windows PowerShell."
