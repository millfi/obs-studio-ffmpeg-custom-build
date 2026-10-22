<#
.SYNOPSIS
Resolve the versions declared in sources.psd1, download every pinned source and
dependency, and store them in the source cache as 7-Zip (Zstandard) archives,
updating sources.lock so Build-Reproduce.ps1 can build fully offline.
.DESCRIPTION
The online half of the download/build split (the Cargo.toml / Cargo.lock model):

  sources.psd1   what you edit: a tag, branch or commit per repository
  sources.lock   what the build reads: resolved commits + archive SHA256 (generated)
  source-cache/  the .7z archives themselves (git-<repo>, codec-sources, atl,
                 official-dependencies)

Only the declarations whose rev string changed (or that are missing from the
lock) are re-resolved and re-downloaded, so bumping one version touches one
archive. Copy the source-cache directory next to Build-Reproduce.ps1 (or pass
-SourceCache to the build); the build then runs without any network access.

The eight work units run concurrently wherever their inputs allow: every git
checkout/pack at once, the fixed downloads as soon as the source tree they read
is packed (official-dependencies follows obs-studio, codec-sources follows
obs-deps). -ThrottleLimit caps how many run at the same time.

Needs git and a Zstandard-capable 7z on PATH. Downloaded files and git commits
are verified against the pinned hashes/commits.
.PARAMETER Package
Only re-resolve these entries (like "cargo update -p"). Known names: the
repositories in sources.psd1 plus atl, official-dependencies, codec-sources.
.PARAMETER Update
Re-resolve every declaration, including unchanged ones (for branches that moved).
.PARAMETER Locked
Fail instead of changing anything when sources.lock is out of date
(the equivalent of "cargo build --locked").
.PARAMETER Force
Re-download and re-pack every archive, even when the lock is current.
.PARAMETER KeepStaging
Keep source-cache/.staging (git checkouts and downloaded files) for inspection.
.PARAMETER ThrottleLimit
How many download/pack tasks may run at the same time (default: half the
processor count, at least 2).
#>
[CmdletBinding()]
param(
    [string]$SourceCache,
    [string[]]$Package,
    [switch]$Update,
    [switch]$Locked,
    [switch]$Force,
    [switch]$KeepStaging,
    [int]$ThrottleLimit
)
$ErrorActionPreference = 'Stop'
# git/7z report in UTF-8; decode it as such instead of with the Japanese
# console code page (Build-Reproduce.ps1 pins the console the same way).
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }
$root = $PSScriptRoot
. "$root/repro/SourceCache.ps1"
. "$root/repro/ParallelTasks.ps1"
if (!$SourceCache) { $SourceCache = "$root/source-cache" }
$SourceCache = [IO.Path]::GetFullPath($SourceCache)
Get-SevenZip | Out-Null
if (!(Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'git.exe must be on PATH.' }
if ($ThrottleLimit -lt 1) { $ThrottleLimit = [Math]::Max(2, [int][Math]::Ceiling([Environment]::ProcessorCount / 2)) }

$staging = "$SourceCache/.staging"
$repos = "$staging/repos"
$files = "$staging/files"
$resultsDir = "$staging/results"
New-Item -ItemType Directory -Force $SourceCache, $repos, $files, $resultsDir | Out-Null

$lock = Read-SourceLock $root
$declarations = @(Get-DeclaredRepositories $root)
$extraNames = @('atl', 'official-dependencies', 'codec-sources')
$selectedPackages = @($Package | Where-Object { $_ })
foreach ($name in $selectedPackages) {
    if ($name -notin @($declarations.Name) -and $name -notin $extraNames) {
        throw "Unknown package '$name'. Known: $((@($declarations.Name) + $extraNames) -join ', ')"
    }
}
function Test-PackageSelected([string]$Name) { ($selectedPackages.Count -eq 0) -or ($Name -in $selectedPackages) }
function Test-PackageForced([string]$Name) { $Force -or $Update -or ($selectedPackages.Count -gt 0 -and ($Name -in $selectedPackages)) }
# -Update re-resolves git declarations only: the fixed-URL downloads have no
# ref to re-resolve, their pin already follows the pinned source trees.
function Test-DownloadForced([string]$Name) { $Force -or ($selectedPackages.Count -gt 0 -and ($Name -in $selectedPackages)) }

# --- Parallel task graph ----------------------------------------------------
# Each work unit runs in its own thread job (repro/ParallelTasks.ps1) with the
# context object below and its own arguments; it writes the sources.lock entry
# it produced to its result file, so the parent only assembles the lock at the
# end. The prelude restores the small helper environment every body needs.
$shared = [pscustomobject]@{
    Root = $root; SourceCache = $SourceCache; Staging = $staging
    Repos = $repos; Files = $files
}
$taskPrelude = {
    $ErrorActionPreference = 'Stop'
    . "$($Shared.Root)/repro/SourceCache.ps1"
}.ToString()

# --- Declared git sources ---------------------------------------------------
$gitTaskBody = {
    param($Decl, $LockedEntry, $Archive, $Flags, $ResultFile)
    $entry = $null
    if (!$Flags.Selected -and $LockedEntry) {
        $entry = $LockedEntry
    } elseif (!$Flags.Forced -and (Test-CachedEntry -Archive $Archive -LockedEntry $LockedEntry -Pin $Decl.Rev -PinField 'rev')) {
        Write-Output "[SKIP] $(Split-Path $Archive -Leaf) (sources.lock is current)"
        $entry = $LockedEntry
    } else {
        if ($Flags.Locked) {
            throw "sources.lock is out of date for '$($Decl.Name)' ($($Decl.Rev)). Run Download-Sources.ps1 without -Locked, then rebuild."
        }
        Write-Output "[SOURCE] $($Decl.Name) rev=$($Decl.Rev)"
        $commit = Resolve-GitCommit $Decl.Url $Decl.Rev
        $reuseArchive = $LockedEntry -and ($LockedEntry.commit -eq $commit) -and (Test-Path -LiteralPath $Archive) -and
                        ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -eq $LockedEntry.sha256) -and !$Flags.Force
        if ($reuseArchive) {
            Write-Output "[REUSE] $($Decl.Name) $commit (already packed; only the declaration text changed)"
        } else {
            Get-SourceCheckout $Decl $commit "$($Shared.Repos)/$($Decl.Name)"
            Compress-SourceArchive $Archive $Shared.Repos @($Decl.Name)
        }
        $entry = [pscustomobject]@{
            name = $Decl.Name
            url = $Decl.Url
            rev = $Decl.Rev
            commit = $commit
            submodules = [bool]$Decl.Submodules
            core_abbrev = [int]$Decl.CoreAbbrev
            archive = "git-$($Decl.Name).7z"
            sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
        }
    }
    $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultFile
}

# --- ATL VSIX development files (pin = the pinned hash table) ---------------
$atlTaskBody = {
    param($Atl, $LockedEntry, $Archive, $Pin, $Flags, $ResultFile)
    $entry = $null
    if (!$Flags.Selected -and $LockedEntry) {
        $entry = $LockedEntry
    } elseif (!$Flags.Forced -and (Test-CachedEntry -Archive $Archive -LockedEntry $LockedEntry -Pin $Pin -PinField 'pin')) {
        Write-Output '[SKIP] atl.7z (sources.lock is current)'
        $entry = $LockedEntry
    } else {
        if ($Flags.Locked) { throw "sources.lock is out of date for 'atl'. Run Download-Sources.ps1 without -Locked, then rebuild." }
        $atlDir = "$($Shared.Files)/atl"
        New-Item -ItemType Directory -Force $atlDir | Out-Null
        $atlNames = foreach ($part in $Atl.Files.Keys) {
            $file = Get-PinnedAtlFileName $part
            Get-DownloadedFile "$($Atl.Base)/$($Atl.Files[$part])/$file" "$atlDir/$file" $Atl.Files[$part]
            $file
        }
        Compress-SourceArchive $Archive $atlDir @($atlNames)
        $entry = [pscustomobject]@{
            name = 'atl'; archive = 'atl.7z'; pin = $Pin
            sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
        }
    }
    $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultFile
}

# --- Official prebuilt OBS dependencies (pin = the pinned obs-studio) -------
# The pin is the commit of the git-obs-studio task, read from its result file,
# so this task only becomes runnable once obs-studio is packed (Depends below).
$depsTaskBody = {
    param($LockedEntry, $Archive, $Flags, $DepResultFile, $ResultFile)
    $obsStudioCommit = [string](Get-Content -LiteralPath $DepResultFile -Raw | ConvertFrom-Json).commit
    if (!$obsStudioCommit) { throw "sources.lock has no git entry for 'obs-studio'; add it to sources.psd1 and re-run Download-Sources.ps1." }
    $entry = $null
    if (!$Flags.Selected -and $LockedEntry) {
        $entry = $LockedEntry
    } elseif (!$Flags.Forced -and (Test-CachedEntry -Archive $Archive -LockedEntry $LockedEntry -Pin $obsStudioCommit -PinField 'pin')) {
        Write-Output '[SKIP] official-dependencies.7z (sources.lock is current)'
        $entry = $LockedEntry
    } else {
        if ($Flags.Locked) { throw "sources.lock is out of date for 'official-dependencies'. Run Download-Sources.ps1 without -Locked, then rebuild." }
        $depsDir = "$($Shared.Files)/official-dependencies"
        New-Item -ItemType Directory -Force $depsDir | Out-Null
        $specs = Get-OfficialDependencySpecs (Get-StagingCheckout $Shared.SourceCache $Shared.Repos 'obs-studio')
        foreach ($spec in $specs) { Get-DownloadedFile $spec.Url "$depsDir/$($spec.FileName)" $spec.Hash }
        Compress-SourceArchive $Archive $depsDir @($specs.FileName)
        $entry = [pscustomobject]@{
            name = 'official-dependencies'; archive = 'official-dependencies.7z'; pin = $obsStudioCommit
            sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
        }
    }
    $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultFile
}

# --- Codec source trees (pin = the pinned obs-deps recipes) -----------------
# The obs-deps recipes know where each codec comes from and pin its hash; run
# their Setup stage (download + unpack, no build) and pack the resulting trees.
$codecSourcesTaskBody = {
    param($LockedEntry, $Archive, $Flags, $DepResultFile, $ResultFile)
    $obsDepsCommit = [string](Get-Content -LiteralPath $DepResultFile -Raw | ConvertFrom-Json).commit
    if (!$obsDepsCommit) { throw "sources.lock has no git entry for 'obs-deps'; add it to sources.psd1 and re-run Download-Sources.ps1." }
    $entry = $null
    if (!$Flags.Selected -and $LockedEntry) {
        $entry = $LockedEntry
    } elseif (!$Flags.Forced -and (Test-CachedEntry -Archive $Archive -LockedEntry $LockedEntry -Pin $obsDepsCommit -PinField 'pin')) {
        Write-Output '[SKIP] codec-sources.7z (sources.lock is current)'
        $entry = $LockedEntry
    } else {
        if ($Flags.Locked) { throw "sources.lock is out of date for 'codec-sources'. Run Download-Sources.ps1 without -Locked, then rebuild." }
        $work = "$($Shared.Staging)/codec"
        if (!(Test-Path "$work/obs-deps")) { Expand-SourceArchive "$($Shared.SourceCache)/git-obs-deps.7z" $work }
        Copy-Item "$($Shared.Root)/Build-CodecDependencies.ps1" $work -Force
        New-Item -ItemType Directory -Force "$work/repro" | Out-Null
        Copy-Item "$($Shared.Root)/repro/UpstreamAdapters.ps1" "$work/repro" -Force
        Push-Location $work
        try { Exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$work/Build-CodecDependencies.ps1" -DownloadOnly } finally { Pop-Location }
        Compress-SourceArchive $Archive "$work/build" @('codec-sources')
        $entry = [pscustomobject]@{
            name = 'codec-sources'; archive = 'codec-sources.7z'; pin = $obsDepsCommit
            sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
        }
    }
    $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultFile
}

$graph = [ordered]@{}
foreach ($decl in $declarations) {
    $graph["git-$($decl.Name)"] = @{
        Depends = @()
        Body = $gitTaskBody
        Args = @(
            $decl
            (Get-LockedSource $lock $decl.Name)
            "$SourceCache/git-$($decl.Name).7z"
            [pscustomobject]@{
                Selected = [bool](Test-PackageSelected $decl.Name)
                Forced = [bool](Test-PackageForced $decl.Name)
                Force = [bool]$Force
                Locked = [bool]$Locked
            }
            "$resultsDir/git-$($decl.Name).json"
        )
    }
}
$atl = Get-PinnedAtl
$atlPin = Get-PinHash ([ordered]@{ base = $atl.Base; files = $atl.Files })
$graph['atl'] = @{
    Depends = @()
    Body = $atlTaskBody
    Args = @(
        $atl
        (Get-LockedDownload $lock 'atl')
        "$SourceCache/atl.7z"
        $atlPin
        [pscustomobject]@{
            Selected = [bool](Test-PackageSelected 'atl')
            Forced = [bool](Test-DownloadForced 'atl')
            Force = [bool]$Force
            Locked = [bool]$Locked
        }
        "$resultsDir/atl.json"
    )
}
$graph['official-dependencies'] = @{
    Depends = @('git-obs-studio')
    Body = $depsTaskBody
    Args = @(
        (Get-LockedDownload $lock 'official-dependencies')
        "$SourceCache/official-dependencies.7z"
        [pscustomobject]@{
            Selected = [bool](Test-PackageSelected 'official-dependencies')
            Forced = [bool](Test-DownloadForced 'official-dependencies')
            Force = [bool]$Force
            Locked = [bool]$Locked
        }
        "$resultsDir/git-obs-studio.json"
        "$resultsDir/official-dependencies.json"
    )
}
$graph['codec-sources'] = @{
    Depends = @('git-obs-deps')
    Body = $codecSourcesTaskBody
    Args = @(
        (Get-LockedDownload $lock 'codec-sources')
        "$SourceCache/codec-sources.7z"
        [pscustomobject]@{
            Selected = [bool](Test-PackageSelected 'codec-sources')
            Forced = [bool](Test-DownloadForced 'codec-sources')
            Force = [bool]$Force
            Locked = [bool]$Locked
        }
        "$resultsDir/git-obs-deps.json"
        "$resultsDir/codec-sources.json"
    )
}
$run = Invoke-TaskGraph -Tasks $graph -Prelude $taskPrelude -Shared $shared -ThrottleLimit $ThrottleLimit `
    -OnLine { param($task, $line) Write-Host "[$task] $line" }

# --- Assemble sources.lock --------------------------------------------------
$sourceEntries = @($declarations | ForEach-Object {
    Get-Content -LiteralPath "$resultsDir/git-$($_.Name).json" -Raw | ConvertFrom-Json
})
$downloadEntries = @(@('atl', 'official-dependencies', 'codec-sources') | ForEach-Object {
    Get-Content -LiteralPath "$resultsDir/$_.json" -Raw | ConvertFrom-Json
})
$newLock = [pscustomobject]@{
    kind = 'obs-fdk-qsv-sources-lock-v1'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    sources = $sourceEntries
    downloads = $downloadEntries
}
Write-SourceLock $root $newLock | Out-Null
if (!$KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force }
Write-Host "Source cache ready: $SourceCache ($([int]$run.Elapsed.TotalSeconds)s, throttle $ThrottleLimit)"
Write-Host 'Copy the source-cache directory next to Build-Reproduce.ps1 (or pass -SourceCache) to build offline.'
