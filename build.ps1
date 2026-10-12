<#
.SYNOPSIS
    Fetch the latest GitHub Release of every component repo and build the MSI.

.EXAMPLE
    .\build.ps1 -Version 1.0.5
    # -> out\msi\ComponentSuite.msi

.EXAMPLE
    .\build.ps1 -SkipDownload      # rebuild from release zips already in out\downloads\
#>
[CmdletBinding()]
param(
    [string] $Version = '1.0.0',
    [switch] $SkipFetch,      # use out\staging\ exactly as it is
    [switch] $SkipDownload,   # restage from out\downloads\ without hitting GitHub
    [switch] $AllowMissing
)
$ErrorActionPreference = 'Stop'

if (-not $SkipFetch) {
    & "$PSScriptRoot\scripts\Fetch-Artifacts.ps1" -SkipDownload:$SkipDownload -AllowMissing:$AllowMissing
}

dotnet build "$PSScriptRoot\installer\ComponentSuite.wixproj" -c Release -p:ProductVersion=$Version -o "$PSScriptRoot\out\msi" --nologo
if ($LASTEXITCODE) { throw "MSI build failed ($LASTEXITCODE)." }
Write-Host "Built $PSScriptRoot\out\msi\ComponentSuite.msi"
