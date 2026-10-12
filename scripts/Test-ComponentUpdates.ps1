<#
.SYNOPSIS
    Decides whether a scheduled run needs to build a new MSI: true when any
    component's current release differs from what the newest ComponentSuite
    release contains.

.DESCRIPTION
    The newest ComponentSuite release's notes list the tag of every component
    it was built from (the table written by the Build MSI workflow). Each
    component's current release is its latest one, or its pinned 'tag' from
    artifacts.json. If any differ - or there is no ComponentSuite release yet,
    or its notes can't be read - the answer is "changed".

    Writes changed=true|false to $env:GITHUB_OUTPUT (when set) and a table to
    $env:GITHUB_STEP_SUMMARY (when set). Uses $env:GITHUB_TOKEN when present.

.EXAMPLE
    .\scripts\Test-ComponentUpdates.ps1 -Repository Ramesh-Mokkapati/Deployments
#>
[CmdletBinding()]
param(
    [string] $Repository = $env:GITHUB_REPOSITORY,   # this repo, owner/name
    [string] $Manifest   = (Join-Path $PSScriptRoot '..\artifacts.json'),
    [string] $Token      = $env:GITHUB_TOKEN
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$cfg = Get-Content $Manifest -Raw | ConvertFrom-Json
$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'ComponentSuite-check' }
if ($Token) { $headers.Authorization = "Bearer $Token" }

function Get-LatestRelease([string] $ownerRepo) {
    try { Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$ownerRepo/releases/latest" }
    catch {
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Write-Result([bool] $changed, [string] $why, [string[]] $table) {
    Write-Host $why
    if ($env:GITHUB_OUTPUT) { "changed=$($changed.ToString().ToLower())" | Add-Content $env:GITHUB_OUTPUT }
    if ($env:GITHUB_STEP_SUMMARY) { (@("### Scheduled check: $why", '') + $table) -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY }
    $changed
}

# What the newest MSI contains, from its release notes:
# | <id> | <owner/repo> | [<tag>](<url>) | `<commit>` |
$suite = Get-LatestRelease $Repository
if (-not $suite) { return Write-Result $true "No ComponentSuite release yet - building." @() }
$inMsi = @{}
foreach ($line in ($suite.body -split "`n")) {
    if ($line -match '^\|\s*([^|\s]+)\s*\|\s*[^|]+\|\s*\[([^\]]+)\]\(') { $inMsi[$Matches[1]] = $Matches[2] }
}

$table = @("Newest ComponentSuite release: $($suite.tag_name)", '', '| Component | In MSI | Current release | |', '|---|---|---|---|')
$changes = @()
foreach ($c in $cfg.components) {
    $pinned = if ($c.PSObject.Properties['tag'] -and $c.tag) { $c.tag } else { $null }
    $current = if ($pinned) { $pinned } else {
        $rel = Get-LatestRelease "$($cfg.owner)/$($c.repo)"
        if ($rel) { $rel.tag_name } else { $null }
    }
    $had = if ($inMsi.ContainsKey($c.id)) { $inMsi[$c.id] } else { $null }
    $same = $current -and $had -and ($current -eq $had)
    if (-not $same) { $changes += $c.id }
    $table += "| $($c.id) | $(if ($had) { $had } else { '-' }) | $(if ($current) { $current } else { 'none' })$(if ($pinned) { ' (pinned)' }) | $(if ($same) { '' } else { 'changed' }) |"
}
$table | ForEach-Object { Write-Host $_ }

if ($changes) { Write-Result $true "Changed since $($suite.tag_name): $($changes -join ', ') - building." $table }
else          { Write-Result $false "Nothing changed since $($suite.tag_name) - no build needed." $table }
