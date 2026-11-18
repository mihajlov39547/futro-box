
# Sync-PK2-ToFutro.ps1
# Windows -> FUTRO S500
# Git staged changes take priority; otherwise all working-tree changes.
#
# Usage:
#   .\Sync-PK2-ToFutro.ps1 -FutroHost 192.168.0.10
#   .\Sync-PK2-ToFutro.ps1 -FutroHost 192.168.0.10 -Build

param(
    [Parameter(Mandatory = $true)]
    [string]$FutroHost,

    [string]$FutroUser = "aktika",

    [string]$RepoPath = (Join-Path $PSScriptRoot "PekkaKana2-source"),

    [string]$RemoteDir = "/home/aktika/pk2",

    [switch]$Build
)

$ErrorActionPreference = "Stop"

function Assert-Success {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed (exit code $LASTEXITCODE)."
    }
}

function Quote-Shell {
    param([string]$Value)

    # Safe single-quoted string for the remote Linux shell.
    return "'" + $Value.Replace("'", "'\''") + "'"
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$RemoteDir = $RemoteDir.TrimEnd("/")
$Target = "${FutroUser}@${FutroHost}"

Push-Location $RepoPath

try {
    # Verify that this is the expected Git repository.
    $GitRoot = (& git rev-parse --show-toplevel).Trim()
    Assert-Success "Git repository detection"

    if ([IO.Path]::GetFullPath($GitRoot).TrimEnd("\") -ne
        [IO.Path]::GetFullPath($RepoPath).TrimEnd("\")) {
        throw "RepoPath must point to the Git repository root."
    }

    # 1. Check staged changes first.
    $Staged = @(
        & git -c core.quotepath=false diff `
            --cached --name-only --no-renames
    )
    Assert-Success "Git staged diff"

    $UseStaged = $Staged.Count -gt 0

    if ($UseStaged) {
        Write-Host "MODE: STAGED ONLY" -ForegroundColor Cyan

        $Paths = $Staged

        $Deleted = @(
            & git -c core.quotepath=false diff `
                --cached --name-only --no-renames --diff-filter=D
        )
        Assert-Success "Git staged deletions"
    }
    else {
        Write-Host "MODE: ALL LOCAL CHANGES" -ForegroundColor Cyan

        $Modified = @(
            & git -c core.quotepath=false diff `
                --name-only --no-renames
        )
        Assert-Success "Git working-tree diff"

        $Untracked = @(
            & git -c core.quotepath=false ls-files `
                --others --exclude-standard
        )
        Assert-Success "Git untracked files"

        $Paths = @($Modified + $Untracked | Sort-Object -Unique)

        $Deleted = @(
            & git -c core.quotepath=false diff `
                --name-only --no-renames --diff-filter=D
        )
        Assert-Success "Git working-tree deletions"
    }

    $Paths = @($Paths | Where-Object { $_ -ne "" } | Sort-Object -Unique)
    $Deleted = @($Deleted | Where-Object { $_ -ne "" } | Sort-Object -Unique)

    if ($Paths.Count -eq 0) {
        Write-Host "No changes detected. Nothing to send." -ForegroundColor Green
        return
    }

    # Git paths are relative to the repository root.
    foreach ($Path in $Paths) {
        if ($Path -match '(^/|(^|/)\.\.(/|$))') {
            throw "Unsafe Git path: $Path"
        }
    }

    $Uploads = @(
        $Paths | Where-Object { $_ -cnotin $Deleted }
    )

    Write-Host ""
    Write-Host "Changes detected: $($Paths.Count)"
    Write-Host "Uploads: $($Uploads.Count)"
    Write-Host "Deletions: $($Deleted.Count)"
    Write-Host ""

    foreach ($Path in $Uploads) {
        Write-Host "  UPLOAD  $Path" -ForegroundColor Green
    }

    foreach ($Path in $Deleted) {
        Write-Host "  DELETE  $Path" -ForegroundColor Yellow
    }

    # 2. Prepare a temporary transfer package.
    $Id = [Guid]::NewGuid().ToString("N")
    $TempDir = Join-Path ([IO.Path]::GetTempPath()) "pk2-sync-$Id"
    $PayloadDir = Join-Path $TempDir "payload"
    $Archive = Join-Path $TempDir "changes.tar.gz"

    $RemoteArchive = "/tmp/pk2-sync-$Id.tar.gz"

    New-Item -ItemType Directory -Force -Path $PayloadDir | Out-Null

    try {
        foreach ($Path in $Uploads) {
            $Dest = Join-Path $PayloadDir ($Path.Replace("/", "\"))

            $DestParent = Split-Path -Parent $Dest

            New-Item -ItemType Directory -Force `
                -Path $DestParent | Out-Null

            if ($UseStaged) {
                # Export exact staged content, not the current working file.
                $Prefix = $PayloadDir.Replace("\", "/") + "/"

                & git checkout-index --force `
                    "--prefix=$Prefix" -- $Path

                Assert-Success "Export staged file: $Path"
            }
            else {
                $Source = Join-Path $RepoPath ($Path.Replace("/", "\"))

                Copy-Item -LiteralPath $Source `
                    -Destination $Dest -Force
            }
        }

        # 3. Create one archive containing all changed files.
        & tar -czf $Archive -C $PayloadDir .
        Assert-Success "Create transfer archive"

        Write-Host ""
        Write-Host "Uploading changes to $Target ..." -ForegroundColor Cyan

        & scp -q $Archive "${Target}:$RemoteArchive"
        Assert-Success "SCP upload"

        # 4. Apply updates and deletions on FUTRO.
        $Commands = @(
            "set -e",
            "tar -xzf $(Quote-Shell $RemoteArchive) -C $(Quote-Shell $RemoteDir)",
            "rm -f -- $(Quote-Shell $RemoteArchive)"
        )

        foreach ($Path in $Deleted) {
            $RemoteFile = "$RemoteDir/$Path"
            $Commands += "rm -f -- $(Quote-Shell $RemoteFile)"
        }

        if ($Build) {
            $Commands += "cd $(Quote-Shell $RemoteDir) && make -j1"
        }

        $RemoteCommand = $Commands -join "; "

        Write-Host "Applying changes on FUTRO ..." -ForegroundColor Cyan

        & ssh $Target $RemoteCommand
        Assert-Success "Remote update"

        Write-Host ""
        Write-Host "SUCCESS: $($Paths.Count) changed file(s) synced." `
            -ForegroundColor Green

        if ($Build) {
            Write-Host "Remote build completed successfully." `
                -ForegroundColor Green
        }
    }
    finally {
        Remove-Item -LiteralPath $TempDir `
            -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Pop-Location
}
