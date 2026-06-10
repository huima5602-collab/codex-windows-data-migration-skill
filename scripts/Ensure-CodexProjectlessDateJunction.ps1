[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$LocalRoot = (Join-Path $env:USERPROFILE 'Documents\Codex'),

    [Parameter(Mandatory = $true)]
    [string]$StorageRoot,

    [datetime]$Date = (Get-Date),

    [switch]$Watch,

    [int]$PollMilliseconds = 250
)

$ErrorActionPreference = 'Stop'

function Resolve-PlannedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-ExpectedJunction {
    param(
        [System.IO.DirectoryInfo]$Item,
        [string]$Target
    )

    if ($Item.LinkType -ne 'Junction') {
        return $false
    }

    $expected = Resolve-PlannedPath -Path $Target
    foreach ($candidate in @($Item.Target)) {
        if (
            (Resolve-PlannedPath -Path $candidate).Equals(
                $expected,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return $true
        }
    }
    return $false
}

function Remove-VerifiedJunction {
    param(
        [string]$Path,
        [string]$ExpectedTarget
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not (Test-ExpectedJunction -Item $item -Target $ExpectedTarget)) {
        throw "Refusing to remove an unexpected directory link: $Path"
    }

    [System.IO.Directory]::Delete($item.FullName)
}

function Get-DirectoryManifest {
    param([string]$Path)

    $manifest = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $manifest
    }

    $root = (Resolve-PlannedPath -Path $Path) + '\'
    foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force) {
        $manifest[$file.FullName.Substring($root.Length)] = $file.Length
    }
    return $manifest
}

function Test-DirectoryCopied {
    param(
        [string]$Source,
        [string]$Destination
    )

    foreach ($entry in (Get-DirectoryManifest -Path $Source).GetEnumerator()) {
        $destinationFile = Join-Path $Destination $entry.Key
        if (-not (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
            return $false
        }
        if ((Get-Item -LiteralPath $destinationFile -Force).Length -ne $entry.Value) {
            return $false
        }
    }
    return $true
}

function Convert-ToStorageJunction {
    param(
        [string]$LocalPath,
        [string]$StoragePath
    )

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        return
    }

    $item = Get-Item -LiteralPath $LocalPath -Force
    if ($item.LinkType) {
        if (-not (Test-ExpectedJunction -Item $item -Target $StoragePath)) {
            throw "Unexpected link target at $LocalPath"
        }
        return
    }
    if (-not $item.PSIsContainer) {
        throw "Expected a directory at $LocalPath"
    }
    if (-not $PSCmdlet.ShouldProcess($LocalPath, "Move contents to $StoragePath and create a junction")) {
        return
    }

    New-Item -ItemType Directory -Path $StoragePath -Force | Out-Null
    $stagingPath = "$LocalPath.codex-migration-$([guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $LocalPath -Destination $stagingPath

    try {
        New-Item -ItemType Junction -Path $LocalPath -Target $StoragePath | Out-Null
        & robocopy.exe `
            $stagingPath `
            $StoragePath `
            /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "Robocopy failed with exit code $LASTEXITCODE"
        }
        if (-not (Test-DirectoryCopied -Source $stagingPath -Destination $StoragePath)) {
            throw "Copy verification failed for $LocalPath"
        }

        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
    catch {
        if (Test-Path -LiteralPath $LocalPath) {
            $currentItem = Get-Item -LiteralPath $LocalPath -Force
            if (Test-ExpectedJunction -Item $currentItem -Target $StoragePath) {
                Remove-VerifiedJunction -Path $LocalPath -ExpectedTarget $StoragePath
            }
        }
        if (-not (Test-Path -LiteralPath $LocalPath) -and (Test-Path -LiteralPath $stagingPath)) {
            Move-Item -LiteralPath $stagingPath -Destination $LocalPath
        }
        throw
    }
}

function Ensure-ProjectlessStorage {
    param([datetime]$ForDate)

    $localRootPath = Resolve-PlannedPath -Path $LocalRoot
    $storageRootPath = Resolve-PlannedPath -Path $StorageRoot
    $dateName = $ForDate.ToString('yyyy-MM-dd')
    $localDate = Join-Path $localRootPath $dateName
    $storageDate = Join-Path $storageRootPath $dateName

    if (-not (Test-Path -LiteralPath $localRootPath)) {
        throw "The Codex projectless root does not exist: $localRootPath"
    }

    $localRootItem = Get-Item -LiteralPath $localRootPath -Force
    if (-not $localRootItem.PSIsContainer -or $localRootItem.LinkType) {
        throw "The Codex projectless root must be a real directory: $localRootPath"
    }

    if (-not (Test-Path -LiteralPath $storageDate)) {
        if ($PSCmdlet.ShouldProcess($storageDate, 'Create date storage directory')) {
            New-Item -ItemType Directory -Path $storageDate -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $localDate) {
        $dateItem = Get-Item -LiteralPath $localDate -Force
        if ($dateItem.LinkType) {
            if (-not (Test-ExpectedJunction -Item $dateItem -Target $storageDate)) {
                throw "Unexpected date-directory link target: $localDate"
            }
            if ($PSCmdlet.ShouldProcess($localDate, 'Replace date junction with a real directory')) {
                Remove-VerifiedJunction -Path $localDate -ExpectedTarget $storageDate
                New-Item -ItemType Directory -Path $localDate | Out-Null
            }
        }
        elseif (-not $dateItem.PSIsContainer) {
            throw "The Codex date path is not a directory: $localDate"
        }
    }
    elseif ($PSCmdlet.ShouldProcess($localDate, 'Create real date directory')) {
        New-Item -ItemType Directory -Path $localDate | Out-Null
    }

    if ($WhatIfPreference -or -not (Test-Path -LiteralPath $localDate)) {
        return
    }

    foreach ($storedThread in Get-ChildItem -LiteralPath $storageDate -Directory -Force) {
        $localThread = Join-Path $localDate $storedThread.Name
        if (
            -not (Test-Path -LiteralPath $localThread) -and
            $PSCmdlet.ShouldProcess($localThread, "Create compatibility junction to $($storedThread.FullName)")
        ) {
            New-Item -ItemType Junction -Path $localThread -Target $storedThread.FullName | Out-Null
        }
    }

    foreach ($localThread in Get-ChildItem -LiteralPath $localDate -Directory -Force) {
        if ($localThread.LinkType) {
            continue
        }

        $storageThread = Join-Path $storageDate $localThread.Name
        foreach ($childName in @('outputs', 'work')) {
            Convert-ToStorageJunction `
                -LocalPath (Join-Path $localThread.FullName $childName) `
                -StoragePath (Join-Path $storageThread $childName)
        }
    }
}

if ($Watch -and $WhatIfPreference) {
    throw '-Watch and -WhatIf cannot be used together.'
}

do {
    try {
        Ensure-ProjectlessStorage -ForDate $(if ($Watch) { Get-Date } else { $Date })
    }
    catch {
        if (-not $Watch) {
            throw
        }

        $logPath = Join-Path $env:USERPROFILE '.codex\projectless-storage-errors.log'
        "$(Get-Date -Format o) $($_.Exception.Message)" | Add-Content -LiteralPath $logPath
    }

    if ($Watch) {
        Start-Sleep -Milliseconds $PollMilliseconds
    }
} while ($Watch)
