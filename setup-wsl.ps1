param(
    [switch]$DryRun,
    [string]$SourcePath,
    [string]$CodexAppHome,
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

function Resolve-CodexAppHome {
    if ($CodexAppHome) {
        return $CodexAppHome
    }

    $codexPackage = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
    if (-not $codexPackage) {
        return $null
    }

    return (Join-Path $env:USERPROFILE ".codex")
}

function Assert-CodexAppUsesWsl {
    param([Parameter(Mandatory = $true)][string]$AppHome)

    if ($DryRun) {
        return
    }

    $configPath = Join-Path $AppHome "config.toml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Codex App is installed, but '$configPath' does not exist. Open the App, enable WSL agent execution, then rerun setup."
    }

    $configContent = [System.IO.File]::ReadAllText($configPath)
    if ($configContent -notmatch '(?m)^\s*runCodexInWindowsSubsystemForLinux\s*=\s*true\s*(?:#.*)?$') {
        throw "Codex App must use WSL agent execution. Enable it in the App, then rerun setup."
    }
}

$windowsCodexAppHome = Resolve-CodexAppHome
$wslCodexAppHome = $null
if ($windowsCodexAppHome) {
    Assert-CodexAppUsesWsl -AppHome $windowsCodexAppHome
    $wslCodexAppHome = ConvertTo-WslPath -WindowsPath $windowsCodexAppHome
}

if ($SourcePath) {
    $wslRoot = ConvertTo-WslPath -WindowsPath $SourcePath
    if ($DryRun) {
        Write-Output "WSL_ROOT=$wslRoot"
        if ($wslCodexAppHome) {
            Write-Output "CODEX_APP_HOME_WSL=$wslCodexAppHome"
        }
        exit 0
    }

    Write-Host "Starting Codex workstation setup from local files..."
    $wslInstallScript = "$wslRoot/install.sh"
    wsl.exe test -f $wslInstallScript
    if ($LASTEXITCODE -ne 0) {
        throw "install.sh was not found at '$wslInstallScript'."
    }
    if ($wslCodexAppHome) {
        wsl.exe env "CODEX_APP_HOME=$wslCodexAppHome" bash $wslInstallScript
    } else {
        Write-Host "Codex App was not detected; skipping its local bootstrap environment."
        wsl.exe bash $wslInstallScript
    }
} else {
    if ($DryRun) {
        Write-Output "WSL_GIT_REPOSITORY=$Repository"
        Write-Output "WSL_GIT_REF=$Ref"
        if ($wslCodexAppHome) {
            Write-Output "CODEX_APP_HOME_WSL=$wslCodexAppHome"
        }
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
        if ($wslCodexAppHome) {
            wsl.exe env "BOOTSTRAP_REPOSITORY=$Repository" "BOOTSTRAP_REF=$Ref" "CODEX_APP_HOME=$wslCodexAppHome" bash $wslUpdaterPath
        } else {
            Write-Host "Codex App was not detected; skipping its local bootstrap environment."
            wsl.exe env "BOOTSTRAP_REPOSITORY=$Repository" "BOOTSTRAP_REF=$Ref" bash $wslUpdaterPath
        }
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $temporaryScript
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Setup failed with exit code $LASTEXITCODE."
}

Write-Host "Setup complete. Restart Codex CLI and Codex App, then open /hooks in each and trust the reviewed RTK Safe Hook."
