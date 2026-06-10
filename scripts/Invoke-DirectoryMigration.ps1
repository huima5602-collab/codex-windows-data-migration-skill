[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [switch]$Resume,

    [string]$CleanupTaskName
)

$ErrorActionPreference = 'Stop'

function Write-AuditLog {
    param(
        [string]$Path,
        [string]$Message
    )

    if (-not $Path) {
        return
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Add-Content -LiteralPath $Path -Encoding UTF8 -Value (
        '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    )
}

function Resolve-PlannedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-IsCodexProjectlessRoot {
    param([string]$Path)

    $projectlessRoot = Resolve-PlannedPath -Path (
        Join-Path $env:USERPROFILE 'Documents\Codex'
    )
    return $Path.Equals(
        $projectlessRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )
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

function Assert-SafeEndpoint {
    param(
        [string]$Path,
        [string[]]$AllowedRoots,
        [string]$Label
    )

    $fullPath = Resolve-PlannedPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')

    if ($fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label cannot be a drive root: $fullPath"
    }

    if (-not (Test-PathBelowRoot -Path $fullPath -Roots $AllowedRoots)) {
        throw "$Label is outside its allowed roots: $fullPath"
    }

    return $fullPath
}

function Get-TreeSummary {
    param([string]$Path)

    $files = New-Object System.Collections.Generic.List[object]
    $directories = New-Object System.Collections.Generic.Queue[string]
    $directories.Enqueue($Path)

    while ($directories.Count -gt 0) {
        $current = $directories.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) {
            if ($item.PSIsContainer) {
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $directories.Enqueue($item.FullName)
                }
            }
            else {
                $files.Add($item)
            }
        }
    }

    $measure = $files | Measure-Object -Property Length -Sum
    $reparseSignatures = @(
        Get-ReparsePointManifest -Path $Path |
            ForEach-Object {
                '{0}|{1}|{2}' -f $_.RelativePath, $_.LinkType, ($_.Target -join ';')
            } |
            Sort-Object
    )

    return [pscustomobject]@{
        FileCount = [int64]$measure.Count
        TotalBytes = [int64]$measure.Sum
        ReparseSignatures = $reparseSignatures
    }
}

function Get-ReparsePointManifest {
    param([string]$Path)

    $root = Resolve-PlannedPath -Path $Path
    $items = @(
        Get-ChildItem -LiteralPath $root -Force -Recurse -Attributes ReparsePoint `
            -ErrorAction SilentlyContinue
    )

    foreach ($item in $items) {
        [pscustomobject]@{
            RelativePath = $item.FullName.Substring($root.Length).TrimStart('\')
            LinkType = $item.LinkType
            Target = @($item.Target)
            IsDirectory = $item.PSIsContainer
        }
    }
}

function Sync-ReparsePoints {
    param(
        [string]$Source,
        [string]$Destination,
        [bool]$AllowReplacement
    )

    $manifest = @(
        Get-ReparsePointManifest -Path $Source |
            Sort-Object { ($_.RelativePath -split '\\').Count }
    )

    foreach ($entry in $manifest) {
        if ($entry.LinkType -notin @('Junction', 'SymbolicLink')) {
            throw "Unsupported reparse point type '$($entry.LinkType)' at $($entry.RelativePath)."
        }

        $destinationLink = Join-Path $Destination $entry.RelativePath
        if (Test-Path -LiteralPath $destinationLink) {
            $existing = Get-Item -LiteralPath $destinationLink -Force
            if (-not $existing.LinkType) {
                $hasContent = $existing.PSIsContainer -and
                    @(Get-ChildItem -LiteralPath $destinationLink -Force).Count -gt 0
                if ($hasContent -and -not $AllowReplacement) {
                    throw "Refusing to replace a non-empty destination path with a link: $destinationLink"
                }
            }

            Remove-Item -LiteralPath $destinationLink -Recurse -Force
        }

        $parent = Split-Path -Parent $destinationLink
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        New-Item `
            -ItemType $entry.LinkType `
            -Path $destinationLink `
            -Target ($entry.Target | Select-Object -First 1) | Out-Null
    }
}

function Assert-SummariesMatch {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Context
    )

    if (
        $Expected.FileCount -ne $Actual.FileCount -or
        $Expected.TotalBytes -ne $Actual.TotalBytes
    ) {
        throw "$Context failed: file count or total bytes do not match."
    }

    if (
        (Compare-Object `
            -ReferenceObject @($Expected.ReparseSignatures) `
            -DifferenceObject @($Actual.ReparseSignatures)).Count -ne 0
    ) {
        throw "$Context failed: reparse point manifests do not match."
    }
}

function Invoke-Robocopy {
    param(
        [string]$Source,
        [string]$Destination,
        [bool]$Mirror
    )

    $arguments = @(
        $Source,
        $Destination,
        $(if ($Mirror) { '/MIR' } else { '/E' }),
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/XJ',
        '/R:3',
        '/W:2',
        '/NP',
        '/NFL',
        '/NDL'
    )

    & robocopy @arguments | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "Robocopy failed with exit code $LASTEXITCODE."
    }
}

$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $resolvedConfig -Raw -Encoding UTF8 |
    ConvertFrom-Json

if (-not $config.migrations -or -not $config.allowedSourceRoots -or
    -not $config.allowedDestinationRoots) {
    throw 'Config must define migrations, allowedSourceRoots, and allowedDestinationRoots.'
}

$logPath = if ($config.logPath) {
    Resolve-PlannedPath -Path $config.logPath
}
else {
    $null
}

foreach ($migration in $config.migrations) {
    $source = Assert-SafeEndpoint `
        -Path $migration.source `
        -AllowedRoots $config.allowedSourceRoots `
        -Label 'Source'
    $destination = Assert-SafeEndpoint `
        -Path $migration.destination `
        -AllowedRoots $config.allowedDestinationRoots `
        -Label 'Destination'

    if (Test-IsCodexProjectlessRoot -Path $source) {
        throw (
            'The Codex projectless root must remain a real directory. ' +
            'Use Install-CodexProjectlessStorage.ps1 instead: ' +
            $source
        )
    }

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source does not exist: $source"
    }

    $sourceItem = Get-Item -LiteralPath $source -Force
    if ($sourceItem.LinkType -eq 'Junction') {
        $currentTarget = Resolve-PlannedPath -Path ($sourceItem.Target | Select-Object -First 1)
        if ($currentTarget.Equals(
            $destination,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            Write-AuditLog -Path $logPath -Message "Already migrated: $source"
            continue
        }

        throw "Source is already a junction with a different target: $source"
    }

    if ([System.IO.Path]::GetPathRoot($source).Equals(
        [System.IO.Path]::GetPathRoot($destination),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Source and destination must be on different volumes: $source"
    }

    $sourceSummary = Get-TreeSummary -Path $source
    $destinationRoot = [System.IO.Path]::GetPathRoot($destination)
    $drive = Get-PSDrive -Name $destinationRoot.Substring(0, 1)
    if ($drive.Free -le ($sourceSummary.TotalBytes * 1.05)) {
        throw "Insufficient free space for: $destination"
    }

    $destinationExists = Test-Path -LiteralPath $destination
    $destinationItemCount = if ($destinationExists) {
        @(Get-ChildItem -LiteralPath $destination -Force).Count
    }
    else {
        0
    }

    if ($destinationExists -and $destinationItemCount -gt 0 -and -not $Resume) {
        throw "Destination is not empty. Inspect it and rerun with -Resume: $destination"
    }

    if (-not $PSCmdlet.ShouldProcess(
        $source,
        "Migrate to $destination and replace the source with an NTFS junction"
    )) {
        continue
    }

    Write-AuditLog -Path $logPath -Message "Starting migration: $source -> $destination"

    $destinationParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    if (-not $destinationExists) {
        New-Item -ItemType Directory -Path $destination | Out-Null
    }

    Invoke-Robocopy -Source $source -Destination $destination -Mirror ([bool]$Resume)
    Sync-ReparsePoints `
        -Source $source `
        -Destination $destination `
        -AllowReplacement ([bool]$Resume)
    $destinationSummary = Get-TreeSummary -Path $destination
    Assert-SummariesMatch `
        -Expected $sourceSummary `
        -Actual $destinationSummary `
        -Context 'Copy verification'

    $temporarySource = "$source.migration-old-$([Guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $source -Destination $temporarySource

    try {
        New-Item -ItemType Junction -Path $source -Target $destination | Out-Null

        $junction = Get-Item -LiteralPath $source -Force
        if ($junction.LinkType -ne 'Junction') {
            throw "Failed to create a junction at: $source"
        }

        $oldSummary = Get-TreeSummary -Path $temporarySource
        $junctionSummary = Get-TreeSummary -Path $source
        Assert-SummariesMatch `
            -Expected $oldSummary `
            -Actual $junctionSummary `
            -Context 'Post-switch verification'

        Remove-Item -LiteralPath $temporarySource -Recurse -Force
        Write-AuditLog -Path $logPath -Message "Completed migration: $source -> $destination"
    }
    catch {
        if (Test-Path -LiteralPath $source) {
            $currentItem = Get-Item -LiteralPath $source -Force
            if ($currentItem.LinkType -eq 'Junction') {
                Remove-Item -LiteralPath $source -Force
            }
        }

        if (Test-Path -LiteralPath $temporarySource) {
            Move-Item -LiteralPath $temporarySource -Destination $source
        }

        Write-AuditLog -Path $logPath -Message "Rolled back migration: $source"
        throw
    }
}

if ($CleanupTaskName) {
    Unregister-ScheduledTask `
        -TaskName $CleanupTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
}
