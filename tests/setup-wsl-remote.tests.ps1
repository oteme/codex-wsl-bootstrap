$ErrorActionPreference = "Stop"

$remoteScript = "https://raw.githubusercontent.com/oteme/codex-wsl-bootstrap/main/setup-wsl.ps1"
$downloadedScript = Join-Path $env:TEMP ("codex-wsl-bootstrap-test-" + [guid]::NewGuid().ToString() + ".ps1")

try {
    Invoke-WebRequest -UseBasicParsing -Uri $remoteScript -OutFile $downloadedScript
    $result = @(& $downloadedScript -DryRun)
    $expected = @(
        "WSL_GIT_REPOSITORY=https://github.com/oteme/codex-wsl-bootstrap.git",
        "WSL_GIT_REF=main"
    )

    if (($result -join "`n") -ne ($expected -join "`n")) {
        throw "Unexpected downloaded launcher output: $($result -join ', ')"
    }
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $downloadedScript
}

Write-Output "PASS: GitHub launcher download and execution work in Windows PowerShell."
