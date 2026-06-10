[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageRoot,

    [string]$LocalRoot = (Join-Path $env:USERPROFILE 'Documents\Codex'),

    [string]$TaskName = 'Codex-Ensure-Projectless-Date-Junction'
)

$ErrorActionPreference = 'Stop'

function Resolve-PlannedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Remove-VerifiedDirectoryLink {
    param(
        [string]$Path,
        [string]$ExpectedTarget
    )

    $item = Get-Item -LiteralPath $Path -Force
    $target = @($item.Target) | Select-Object -First 1
    if (
        $item.LinkType -ne 'Junction' -or
        -not (Resolve-PlannedPath -Path $target).Equals(
            $ExpectedTarget,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Refusing to remove an unverified directory link: $Path"
    }

    [System.IO.Directory]::Delete($Path, $false)
}

function Remove-PreparedRoot {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        if ($item.LinkType -ne 'Junction') {
            throw "Refusing to clean an unexpected staging item: $($item.FullName)"
        }
        [System.IO.Directory]::Delete($item.FullName, $false)
    }

    [System.IO.Directory]::Delete($Path, $false)
}

$localRootPath = Resolve-PlannedPath -Path $LocalRoot
$storageRootPath = Resolve-PlannedPath -Path $StorageRoot
$maintenanceScript = Join-Path $PSScriptRoot 'Ensure-CodexProjectlessDateJunction.ps1'
$localParent = Split-Path -Parent $localRootPath
$stagingRoot = "$localRootPath.real-$([Guid]::NewGuid().ToString('N'))"
$convertedRoot = $false

if (
    [System.IO.Path]::GetPathRoot($localRootPath).Equals(
        [System.IO.Path]::GetPathRoot($storageRootPath),
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw 'LocalRoot and StorageRoot must be on different volumes.'
}

if (-not (Test-Path -LiteralPath $storageRootPath)) {
    throw "StorageRoot does not exist: $storageRootPath"
}

if (-not (Test-Path -LiteralPath $localParent)) {
    throw "LocalRoot parent does not exist: $localParent"
}

if (Test-Path -LiteralPath $localRootPath) {
    $localItem = Get-Item -LiteralPath $localRootPath -Force
    if ($localItem.LinkType) {
        $currentTarget = @($localItem.Target) | Select-Object -First 1
        if (
            $localItem.LinkType -ne 'Junction' -or
            -not (Resolve-PlannedPath -Path $currentTarget).Equals(
                $storageRootPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "LocalRoot is a link to an unexpected target: $localRootPath"
        }

        if ($PSCmdlet.ShouldProcess(
            $localRootPath,
            'Replace the root junction with a real directory and date junctions'
        )) {
            New-Item -ItemType Directory -Path $stagingRoot | Out-Null
            try {
                foreach (
                    $directory in Get-ChildItem -LiteralPath $storageRootPath -Directory -Force |
                        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }
                ) {
                    New-Item `
                        -ItemType Junction `
                        -Path (Join-Path $stagingRoot $directory.Name) `
                        -Target $directory.FullName | Out-Null
                }

                Remove-VerifiedDirectoryLink `
                    -Path $localRootPath `
                    -ExpectedTarget $storageRootPath
                Move-Item -LiteralPath $stagingRoot -Destination $localRootPath
                $convertedRoot = $true
            }
            catch {
                if (
                    -not (Test-Path -LiteralPath $localRootPath) -and
                    (Test-Path -LiteralPath $storageRootPath)
                ) {
                    New-Item `
                        -ItemType Junction `
                        -Path $localRootPath `
                        -Target $storageRootPath | Out-Null
                }
                Remove-PreparedRoot -Path $stagingRoot
                throw
            }
        }
    }
    elseif (-not $localItem.PSIsContainer) {
        throw "LocalRoot is not a directory: $localRootPath"
    }
}
elseif ($PSCmdlet.ShouldProcess($localRootPath, 'Create real Codex projectless root')) {
    New-Item -ItemType Directory -Path $localRootPath | Out-Null
}

if (-not $WhatIfPreference) {
    foreach (
        $directory in Get-ChildItem -LiteralPath $storageRootPath -Directory -Force |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' }
    ) {
        $parsedDate = [datetime]::MinValue
        if ([datetime]::TryParseExact(
            $directory.Name,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )) {
            & $maintenanceScript `
                -LocalRoot $localRootPath `
                -StorageRoot $storageRootPath `
                -Date $parsedDate
        }
    }

    & $maintenanceScript -LocalRoot $localRootPath -StorageRoot $storageRootPath
}

$taskArguments = (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -LocalRoot "{1}" -StorageRoot "{2}"' -f
        $maintenanceScript,
        $localRootPath,
        $storageRootPath
)

if ($PSCmdlet.ShouldProcess($TaskName, 'Register daily and logon maintenance task')) {
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument $taskArguments
    $triggers = @(
        New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        New-ScheduledTaskTrigger -Daily -At '00:01'
    )
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $triggers `
        -Settings $settings `
        -Description 'Keep Codex projectless date directories on the configured storage drive.' `
        -Force | Out-Null
}

if (-not $WhatIfPreference) {
    $rootItem = Get-Item -LiteralPath $localRootPath -Force
    if (-not $rootItem.PSIsContainer -or $rootItem.LinkType) {
        throw "Post-install validation failed for LocalRoot: $localRootPath"
    }
}

[pscustomobject]@{
    LocalRoot = $localRootPath
    StorageRoot = $storageRootPath
    RootConverted = $convertedRoot
    TaskName = $TaskName
    WhatIf = [bool]$WhatIfPreference
}
