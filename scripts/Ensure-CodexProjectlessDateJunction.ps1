[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$LocalRoot = (Join-Path $env:USERPROFILE 'Documents\Codex'),

    [Parameter(Mandatory = $true)]
    [string]$StorageRoot,

    [datetime]$Date = (Get-Date)
)

$ErrorActionPreference = 'Stop'

function Resolve-PlannedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

$localRootPath = Resolve-PlannedPath -Path $LocalRoot
$storageRootPath = Resolve-PlannedPath -Path $StorageRoot
$dateName = $Date.ToString('yyyy-MM-dd')
$localDate = Join-Path $localRootPath $dateName
$storageDate = Join-Path $storageRootPath $dateName

if (-not (Test-Path -LiteralPath $localRootPath)) {
    throw "The Codex projectless root does not exist: $localRootPath"
}

$localRootItem = Get-Item -LiteralPath $localRootPath -Force
if (-not $localRootItem.PSIsContainer -or $localRootItem.LinkType) {
    throw "The Codex projectless root must be a real directory: $localRootPath"
}

if (-not (Test-Path -LiteralPath $storageRootPath)) {
    if ($PSCmdlet.ShouldProcess($storageRootPath, 'Create Codex storage root')) {
        New-Item -ItemType Directory -Path $storageRootPath -Force | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $storageDate)) {
    if ($PSCmdlet.ShouldProcess($storageDate, 'Create date storage directory')) {
        New-Item -ItemType Directory -Path $storageDate -Force | Out-Null
    }
}

if (Test-Path -LiteralPath $localDate) {
    $item = Get-Item -LiteralPath $localDate -Force
    $target = @($item.Target) | Select-Object -First 1
    if (
        $item.LinkType -ne 'Junction' -or
        -not (Resolve-PlannedPath -Path $target).Equals(
            $storageDate,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "The date path exists but is not the expected junction: $localDate"
    }
    return
}

if ($PSCmdlet.ShouldProcess($localDate, "Create junction to $storageDate")) {
    New-Item -ItemType Junction -Path $localDate -Target $storageDate | Out-Null
}
