[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

function Resolve-ExistingPath {
    param([string]$Path)

    return (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
}

function Resolve-PlannedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathBelowRoot {
    param(
        [string]$Path,
        [string[]]$Roots
    )

    foreach ($root in $Roots) {
        $resolvedRoot = Resolve-PlannedPath -Path $root
        if (
            $Path.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $Path.StartsWith(
                "$resolvedRoot\",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return $true
        }
    }

    return $false
}

function Get-TreeSummary {
    param([string]$Path)

    $files = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction Stop
    $measure = $files | Measure-Object -Property Length -Sum
    $reparsePoints = @(
        Get-ChildItem -LiteralPath $Path -Force -Recurse -Attributes ReparsePoint `
            -ErrorAction SilentlyContinue
    )
    $hiddenFiles = @($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::Hidden })

    return [pscustomobject]@{
        FileCount = [int64]$measure.Count
        TotalBytes = [int64]$measure.Sum
        HiddenFileCount = $hiddenFiles.Count
        ReparsePointCount = $reparsePoints.Count
    }
}

function Get-GitSummary {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        return [pscustomobject]@{
            IsRepository = $false
            Head = $null
            Status = @()
        }
    }

    $head = & git -c "safe.directory=$Path" -C $Path rev-parse --verify HEAD 2>$null
    $status = @(& git -c "safe.directory=$Path" -C $Path status --short 2>$null)

    return [pscustomobject]@{
        IsRepository = $true
        Head = if ($LASTEXITCODE -eq 0) { "$head".Trim() } else { $null }
        Status = $status
    }
}

$resolvedConfig = Resolve-ExistingPath -Path $ConfigPath
$config = Get-Content -LiteralPath $resolvedConfig -Raw -Encoding UTF8 |
    ConvertFrom-Json

if (-not $config.migrations -or -not $config.allowedSourceRoots -or
    -not $config.allowedDestinationRoots) {
    throw 'Config must define migrations, allowedSourceRoots, and allowedDestinationRoots.'
}

$results = foreach ($migration in $config.migrations) {
    $source = Resolve-ExistingPath -Path $migration.source
    $destination = Resolve-PlannedPath -Path $migration.destination

    if (-not (Test-PathBelowRoot -Path $source -Roots $config.allowedSourceRoots)) {
        throw "Source is outside allowedSourceRoots: $source"
    }

    if (-not (Test-PathBelowRoot -Path $destination -Roots $config.allowedDestinationRoots)) {
        throw "Destination is outside allowedDestinationRoots: $destination"
    }

    if ([System.IO.Path]::GetPathRoot($source).Equals(
        [System.IO.Path]::GetPathRoot($destination),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Source and destination must be on different volumes: $source"
    }

    $sourceItem = Get-Item -LiteralPath $source -Force
    $summary = Get-TreeSummary -Path $source
    $git = Get-GitSummary -Path $source
    $destinationExists = Test-Path -LiteralPath $destination
    $destinationItemCount = if ($destinationExists) {
        @(Get-ChildItem -LiteralPath $destination -Force -ErrorAction Stop).Count
    }
    else {
        0
    }

    $destinationRoot = [System.IO.Path]::GetPathRoot($destination)
    $driveName = $destinationRoot.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName

    [pscustomobject]@{
        Source = $source
        SourceLinkType = $sourceItem.LinkType
        Destination = $destination
        DestinationExists = $destinationExists
        DestinationItemCount = $destinationItemCount
        SourceFileCount = $summary.FileCount
        SourceBytes = $summary.TotalBytes
        HiddenFileCount = $summary.HiddenFileCount
        ReparsePointCount = $summary.ReparsePointCount
        DestinationFreeBytes = [int64]$drive.Free
        HasEnoughFreeSpace = $drive.Free -gt ($summary.TotalBytes * 1.05)
        IsGitRepository = $git.IsRepository
        GitHead = $git.Head
        GitStatus = $git.Status
        Ready = (
            -not $sourceItem.LinkType -and
            $drive.Free -gt ($summary.TotalBytes * 1.05) -and
            (-not $destinationExists -or $destinationItemCount -eq 0)
        )
    }
}

$results

