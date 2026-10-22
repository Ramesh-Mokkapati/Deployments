<#
.SYNOPSIS
    Downloads the GitHub Release zip of each repo listed in artifacts.json and
    lays the files out in out\staging\<id>\ for the WiX installer project.

.DESCRIPTION
    For every component, the repo's latest release (GitHub's "latest": drafts and
    pre-releases excluded) is used, unless the component pins a 'tag'. The release
    asset named by the manifest's 'asset' pattern (or the component's own 'asset')
    - e.g. DiskForge-v1.0.0-x64.zip - is downloaded and unzipped, its files are mapped into the staging folder
    according to the component's 'files' rules, and out\staging\build-info.json
    records exactly which release/tag/commit each component came from.

    Release assets of public repos download without a token. A token is still
    used when present ($env:GITHUB_TOKEN; in CI the workflow's own token) to get
    a higher API rate limit, and is required only if a component repo is private
    (then it needs "Contents: read" on that repo).

.PARAMETER SkipDownload
    Reuse whatever is already in out\downloads\<id>\ - e.g. a release zip you
    downloaded and unzipped by hand. No network access.

.PARAMETER AllowMissing
    Skip a component that has no release (or no matching asset) instead of
    failing. The installer project then leaves that feature out.

.EXAMPLE
    .\scripts\Fetch-Artifacts.ps1
#>
[CmdletBinding()]
param(
    [string]   $Manifest = (Join-Path $PSScriptRoot '..\artifacts.json'),
    [string]   $OutDir   = (Join-Path $PSScriptRoot '..\out'),
    [string]   $Token    = $env:GITHUB_TOKEN,
    [string[]] $Only,
    [switch]   $SkipDownload,
    [switch]   $AllowMissing
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on 5.1
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$cfg       = Get-Content $Manifest -Raw | ConvertFrom-Json
$OutDir    = [IO.Path]::GetFullPath($OutDir)
$downloads = Join-Path $OutDir 'downloads'
$staging   = Join-Path $OutDir 'staging'

$headers = @{
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'ComponentSuite-fetch'
}
if ($Token) { $headers.Authorization = "Bearer $Token" }

# Glob -> anchored regex over '/'-separated relative paths.  ** = any depth, * = one segment.
function ConvertTo-GlobRegex([string] $glob) {
    $sb = New-Object Text.StringBuilder '^'
    for ($i = 0; $i -lt $glob.Length; $i++) {
        $ch = $glob[$i]
        if ($ch -eq '*' -and $i + 1 -lt $glob.Length -and $glob[$i + 1] -eq '*') {
            if ($i + 2 -lt $glob.Length -and $glob[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 2 }
            else                                                    { [void]$sb.Append('.*');       $i += 1 }
        }
        elseif ($ch -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($ch -eq '?') { [void]$sb.Append('[^/]') }
        else                 { [void]$sb.Append([regex]::Escape([string]$ch)) }
    }
    [void]$sb.Append('$')
    New-Object Regex ($sb.ToString(), 'IgnoreCase')
}

# Directory part of a glob before the first wildcard, e.g. 'bin/x64/*.dll' -> 'bin/x64/'.
function Get-GlobPrefix([string] $glob) {
    $wild = $glob.IndexOfAny([char[]]'*?')
    if ($wild -lt 0) { $wild = $glob.Length }
    $slash = $glob.LastIndexOf('/', [Math]::Max($wild - 1, 0))
    if ($slash -lt 0) { '' } else { $glob.Substring(0, $slash + 1) }
}

# HTTP status of a failed web request, or $null for network-level failures.
function Get-HttpStatus($err) {
    if ($err.Exception.PSObject.Properties['Response'] -and $err.Exception.Response) { [int]$err.Exception.Response.StatusCode } else { $null }
}

# Runs a web request, retrying GitHub's occasional 5xx / network errors
# (4 attempts, 2-4-8 s apart). 4xx errors are rethrown straight away.
function Invoke-WithRetry([scriptblock] $request, [string] $what) {
    for ($attempt = 1; ; $attempt++) {
        try { return & $request }
        catch {
            $status = Get-HttpStatus $_
            if (($status -and $status -lt 500) -or $attempt -ge 4) { throw }
            $wait = [Math]::Pow(2, $attempt)
            Write-Warning "  $what failed ($(if ($status) { "HTTP $status" } else { $_.Exception.Message })); retrying in $wait s..."
            Start-Sleep -Seconds $wait
        }
    }
}

# GitHub API GET; returns $null on 404 instead of throwing.
function Invoke-GitHubApi([string] $path) {
    $uri = "https://api.github.com/repos/$($cfg.owner)/$path"
    try { Invoke-WithRetry { Invoke-RestMethod -Headers $headers -Uri $uri } "GET $path" }
    catch {
        $status = Get-HttpStatus $_
        if ($status -eq 404) { return $null }
        if ($status -eq 403 -or $status -eq 429) { throw "GitHub API rate limit or access problem on '$path' (HTTP $status). Set `$env:GITHUB_TOKEN and retry. $_" }
        throw
    }
}

# The release to package: the pinned tag, or GitHub's "latest" (no drafts / pre-releases).
function Get-Release($repo, $tag) {
    if ($tag) { Invoke-GitHubApi "$repo/releases/tags/$([uri]::EscapeDataString($tag))" }
    else      { Invoke-GitHubApi "$repo/releases/latest" }
}

# Commit a tag points at (follows annotated tags).
function Get-TagCommit($repo, $tag) {
    $ref = Invoke-GitHubApi "$repo/git/ref/tags/$([uri]::EscapeDataString($tag))"
    if (-not $ref) { return $null }
    $obj = $ref.object
    while ($obj.type -eq 'tag') { $obj = (Invoke-GitHubApi "$repo/git/tags/$($obj.sha)").object }
    $obj.sha
}

$selected = @($cfg.components | Where-Object { -not $Only -or $Only -contains $_.id })
if (-not $selected) { throw "No components selected (-Only $($Only -join ','))." }

if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force $staging, $downloads | Out-Null

$excludes  = @($cfg.exclude | ForEach-Object { ConvertTo-GlobRegex $_ })
$buildInfo = [ordered]@{ generated = (Get-Date).ToUniversalTime().ToString('o'); components = [ordered]@{} }
$missing   = @()
$notReleased = @()

foreach ($c in $selected) {
    $pinned = if ($c.PSObject.Properties['tag'] -and $c.tag) { $c.tag } else { $null }
    Write-Host "==> $($c.id)  ($($cfg.owner)/$($c.repo) @ $(if ($pinned) { $pinned } else { 'latest release' }))"
    $src = Join-Path $downloads $c.id
    $info = [ordered]@{ repo = "$($cfg.owner)/$($c.repo)" }

    if ($SkipDownload) {
        if (-not (Test-Path $src)) {
            if ($AllowMissing) { Write-Warning "  $src not found - skipping"; $missing += $c.id; continue }
            throw "$src not found. Download the $($c.repo) release zip and unzip it there."
        }
        $info.source = 'local'
    }
    else {
        $rel = Get-Release $c.repo $pinned
        $asset = $null
        if ($rel) {
            # A component's own 'asset' overrides the manifest default. {version} is the tag without its leading 'v'.
            $pattern   = if ($c.PSObject.Properties['asset'] -and $c.asset) { $c.asset } else { $cfg.asset }
            $assetName = $pattern.Replace('{repo}', $c.repo).Replace('{tag}', $rel.tag_name).Replace('{version}', ($rel.tag_name -replace '^v', ''))
            $asset = @($rel.assets | Where-Object { $_.name -eq $assetName }) | Select-Object -First 1
        }
        if (-not $asset) {
            # A repo that has never released is skipped when its entry opts in with allowUnreleased;
            # a release without the expected zip, or a missing pinned tag, still fails.
            $allowUnreleased = $c.PSObject.Properties['allowUnreleased'] -and $c.allowUnreleased
            if (-not $rel -and -not $pinned -and $allowUnreleased) {
                Write-Warning "  $($c.repo) has no release yet - skipping (allowUnreleased)."
                $notReleased += $c.id; continue
            }
            $msg =if (-not $rel) { "$($c.repo) has no $(if ($pinned) { "release tagged $pinned" } else { 'published (non-pre-release) release' }). Push a v*.*.* tag there." }
                   else { "$($c.repo) release $($rel.tag_name) has no asset '$assetName' (has: $(@($rel.assets.name) -join ', '))." }
            if ($AllowMissing) { Write-Warning "  $msg Skipping."; $missing += $c.id; continue }
            throw $msg
        }
        $commit = Get-TagCommit $c.repo $rel.tag_name
        Write-Host "    $($rel.tag_name)$(if ($commit) { " ($($commit.Substring(0,7)))" }), published $($rel.published_at): $($asset.name)"

        if (Test-Path $src) { Remove-Item $src -Recurse -Force }
        New-Item -ItemType Directory -Force $src | Out-Null
        $zip = Join-Path $downloads "$($c.id).zip"
        # The asset API URL works for public and private repos; GitHub redirects
        # to storage and the auth header is not forwarded there.
        $dl = $headers.Clone(); $dl.Accept = 'application/octet-stream'
        Invoke-WithRetry { Invoke-WebRequest -Headers $dl -Uri $asset.url -OutFile $zip -UseBasicParsing } "Download of $($asset.name)"
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $src)
        Remove-Item $zip

        $info.tag        = $rel.tag_name
        $info.commit     = $commit
        $info.asset      = $asset.name
        $info.published  = $rel.published_at
        $info.releaseUrl = $rel.html_url
    }

    $root  = (Resolve-Path $src).Path.TrimEnd('\') + '\'
    $files = @(Get-ChildItem $src -Recurse -File | ForEach-Object {
        [pscustomobject]@{ Full = $_.FullName; Rel = $_.FullName.Substring($root.Length).Replace('\', '/') }
    } | Where-Object { $rel = $_.Rel; -not ($excludes | Where-Object { $_.IsMatch($rel) }) })

    $dest   = Join-Path $staging $c.id
    $placed = @{}
    foreach ($m in $c.files) {
        $rx       = ConvertTo-GlobRegex $m.from
        $matches_ = @($files | Where-Object { $rx.IsMatch($_.Rel) })
        $optional = $m.PSObject.Properties['optional'] -and $m.optional
        $keepTree = $m.PSObject.Properties['keepTree'] -and $m.keepTree
        if (-not $matches_) {
            if ($optional) { continue }
            throw "$($c.id): '$($m.from)' matched nothing. The release zip contains:`n  $(($files.Rel | Sort-Object) -join "`n  ")"
        }
        $toDir = ($m.to -eq '' -or $m.to.EndsWith('/'))
        if (-not $toDir -and $matches_.Count -gt 1) { throw "$($c.id): '$($m.from)' matched $($matches_.Count) files but 'to' names a single file." }
        $prefix = Get-GlobPrefix $m.from

        foreach ($f in $matches_) {
            $target = if (-not $toDir) { $m.to }
                      elseif ($keepTree) { $m.to + $f.Rel.Substring($prefix.Length) }
                      else { $m.to + ($f.Rel -split '/')[-1] }
            if ($placed.ContainsKey($target)) { throw "$($c.id): both '$($placed[$target])' and '$($f.Rel)' map to '$target'." }
            $placed[$target] = $f.Rel
            $out = Join-Path $dest ($target.Replace('/', '\'))
            New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
            Copy-Item $f.Full $out
        }
    }
    $info.files = @($placed.Keys | Sort-Object)
    $buildInfo.components[$c.id] = $info
    Write-Host "    staged $($placed.Count) file(s) -> $dest"
}

if ($missing) { $buildInfo.missing = $missing }
if ($notReleased) { $buildInfo.notReleased = $notReleased }
$buildInfo | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $staging 'build-info.json') -Encoding UTF8
Write-Host "Staging ready: $staging"
if ($missing) { Write-Warning "Left out: $($missing -join ', ')" }
if ($notReleased) { Write-Warning "Not released yet, left out: $($notReleased -join ', ')" }
