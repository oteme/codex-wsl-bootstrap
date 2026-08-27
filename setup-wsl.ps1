param(
    [switch]$DryRun,
    [string]$SourcePath,
    [string]$Repository = "https://github.com/oteme/codex-wsl-bootstrap.git",
    [string]$Ref = "main"
)

$ErrorActionPreference = "Stop"

function ConvertTo-WslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    # Windows PowerShell 5.1 removes single backslashes while constructing the
    # native wsl.exe command line. Double them so wslpath receives the original
    # Windows path, including drive letters, spaces, and directory separators.
    $escapedPath = $WindowsPath.Replace("\", "\\")
    $conversionOutput = @(wsl.exe wslpath -a $escapedPath 2>&1)
    $conversionExitCode = $LASTEXITCODE

    if ($conversionExitCode -ne 0) {
        $details = ($conversionOutput | ForEach-Object { $_.ToString() }) -join "`n"
        throw "WSL path conversion failed for '$WindowsPath'. Confirm that WSL2 and Ubuntu are installed.`n$details"
    }

    $convertedPath = (($conversionOutput | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if (-not $convertedPath) {
        throw "WSL path conversion returned an empty path for '$WindowsPath'."
    }

    return $convertedPath
}

if ($SourcePath) {
    $wslRoot = ConvertTo-WslPath -WindowsPath $SourcePath
    if ($DryRun) {
        Write-Output "WSL_ROOT=$wslRoot"
        exit 0
    }

    Write-Host "Starting Codex workstation setup from local files..."
    $wslInstallScript = "$wslRoot/install.sh"
    wsl.exe test -f $wslInstallScript
    if ($LASTEXITCODE -ne 0) {
        throw "install.sh was not found at '$wslInstallScript'."
    }
    wsl.exe bash $wslInstallScript
} else {
    if ($DryRun) {
        Write-Output "WSL_GIT_REPOSITORY=$Repository"
        Write-Output "WSL_GIT_REF=$Ref"
        exit 0
    }

    Write-Host "Updating Codex workstation setup with Git inside WSL..."
    $wslUpdater = @'
set -euo pipefail

repo="$HOME/.local/share/codex-wsl-bootstrap"

if [[ -e "$repo" && ! -d "$repo/.git" ]]; then
  echo "error: $repo exists but is not a Git checkout" >&2
  exit 1
fi

if [[ -d "$repo/.git" ]]; then
  actual_remote="$(git -C "$repo" remote get-url origin)"
  if [[ "$actual_remote" != "$BOOTSTRAP_REPOSITORY" ]]; then
    echo "error: unexpected bootstrap origin: $actual_remote" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
    echo "error: bootstrap checkout contains local changes: $repo" >&2
    exit 1
  fi
else
  mkdir -p "$(dirname "$repo")"
  git clone --filter=blob:none --no-checkout "$BOOTSTRAP_REPOSITORY" "$repo"
fi

echo "Fetching Codex workstation setup: $BOOTSTRAP_REF"
git -C "$repo" fetch --quiet --depth 1 origin "$BOOTSTRAP_REF"
git -C "$repo" checkout --quiet --detach FETCH_HEAD
bash "$repo/install.sh"
'@

    $temporaryScript = [System.IO.Path]::GetTempFileName()
    try {
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryScript, $wslUpdater, $utf8WithoutBom)
        $wslUpdaterPath = ConvertTo-WslPath -WindowsPath $temporaryScript
        wsl.exe env "BOOTSTRAP_REPOSITORY=$Repository" "BOOTSTRAP_REF=$Ref" bash $wslUpdaterPath
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $temporaryScript
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Setup failed with exit code $LASTEXITCODE."
}

Write-Host "Setup complete. Restart Codex CLI, then open /hooks and trust the reviewed RTK Safe Hook."
