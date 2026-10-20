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
#>
[CmdletBinding()]
param(
    [string]$SourceCache,
    [string[]]$Package,
    [switch]$Update,
    [switch]$Locked,
    [switch]$Force,
    [switch]$KeepStaging
)
$ErrorActionPreference = 'Stop'
# git/7z report in UTF-8; decode it as such instead of with the Japanese
# console code page (Build-Reproduce.ps1 pins the console the same way).
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }
$root = $PSScriptRoot
. "$root/repro/SourceCache.ps1"
if (!$SourceCache) { $SourceCache = "$root/source-cache" }
$SourceCache = [IO.Path]::GetFullPath($SourceCache)
Get-SevenZip | Out-Null
if (!(Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'git.exe must be on PATH.' }

function Exec {
    $command = $args[0]
    $arguments = @($args | Select-Object -Skip 1)
    & $command @arguments
    if ($LASTEXITCODE) { throw "Command failed ($LASTEXITCODE): $command $($arguments -join ' ')" }
}

function Get-DownloadedFile([string]$Url, [string]$Path, [string]$Sha256) {
    if (!(Test-Path -LiteralPath $Path)) {
        Write-Host "[DOWNLOAD] $Url"
        Invoke-WebRequest -Uri $Url -OutFile "$Path.partial" -MaximumRetryCount 3
        if ((Get-FileHash "$Path.partial").Hash -ne $Sha256) { throw "SHA256 mismatch: $Url" }
        Move-Item -LiteralPath "$Path.partial" -Destination $Path
    }
    if ((Get-FileHash $Path).Hash -ne $Sha256) { throw "Cached SHA256 mismatch: $Path" }
}

function Get-SourceCheckout($Decl, [string]$Commit, [string]$Path) {
    # Shallow checkout of the resolved commit, plus the optional extra history
    # and tag refs that make "git describe" report the same version string as
    # the original build.
    if (!(Test-Path "$Path/.git")) { Exec git init $Path }
    if ('origin' -notin @(& git -C $Path remote)) { Exec git -C $Path remote add origin $Decl.Url }
    $head = & git -C $Path rev-parse --verify HEAD 2>$null
    if ($head -and $head -ne $Commit) { throw "Refusing to overwrite existing $($Decl.Name) commit $head (expected $Commit)." }
    if ($head -ne $Commit) {
        Exec git -C $Path fetch --depth 1 origin $Commit
        Exec git -C $Path checkout --detach $Commit
        if ($Decl.History) { Exec git -C $Path fetch --deepen $Decl.History origin $Commit }
        foreach ($tag in $Decl.Tags) { Exec git -C $Path fetch --depth 1 origin "refs/tags/$tag" }
        if ($Decl.Submodules) { Exec git -C $Path submodule update --init --recursive }
    }
    if ($Decl.CoreAbbrev) { Exec git -C $Path config core.abbrev $Decl.CoreAbbrev }
    if ((& git -C $Path rev-parse HEAD) -ne $Commit) { throw "Commit verification failed: $($Decl.Name)" }
}

$staging = "$SourceCache/.staging"
$repos = "$staging/repos"
$files = "$staging/files"
New-Item -ItemType Directory -Force $SourceCache, $repos, $files | Out-Null

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

function Test-CachedEntry {
    # The archive is present and the lock records it with the same pin, so the
    # entry can be carried forward without touching the network. The lock entry
    # parameter must not be called $Locked: that would collide with the script's
    # -Locked switch in the same scope and hit its switch type.
    param([string]$Archive, $LockedEntry, [string]$Pin, [string]$PinField)
    if (!$LockedEntry) { return $false }
    if ([string]$LockedEntry.$PinField -ne $Pin) { return $false }
    if (!(Test-Path -LiteralPath $Archive)) { return $false }
    return ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -eq $LockedEntry.sha256)
}

# --- Declared git sources --------------------------------------------------
$sourceEntries = [Collections.Generic.List[object]]::new()
foreach ($decl in $declarations) {
    $archive = "$SourceCache/git-$($decl.Name).7z"
    $lockedEntry = Get-LockedSource $lock $decl.Name
    if (!(Test-PackageSelected $decl.Name) -and $lockedEntry) {
        $sourceEntries.Add($lockedEntry)
        continue
    }
    if (!(Test-PackageForced $decl.Name) -and (Test-CachedEntry -Archive $archive -LockedEntry $lockedEntry -Pin $decl.Rev -PinField 'rev')) {
        Write-Host "[SKIP] $(Split-Path $archive -Leaf) (sources.lock is current)"
        $sourceEntries.Add($lockedEntry)
        continue
    }
    if ($Locked) {
        throw "sources.lock is out of date for '$($decl.Name)' ($($decl.Rev)). Run Download-Sources.ps1 without -Locked, then rebuild."
    }
    Write-Host "[SOURCE] $($decl.Name) rev=$($decl.Rev)"
    $commit = Resolve-GitCommit $decl.Url $decl.Rev
    $reuseArchive = $lockedEntry -and ($lockedEntry.commit -eq $commit) -and (Test-Path -LiteralPath $archive) -and
                    ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -eq $lockedEntry.sha256) -and !$Force
    if ($reuseArchive) {
        Write-Host "[REUSE] $($decl.Name) $commit (already packed; only the declaration text changed)"
    } else {
        Get-SourceCheckout $decl $commit "$repos/$($decl.Name)"
        Compress-SourceArchive $archive $repos @($decl.Name)
    }
    $sourceEntries.Add([pscustomobject]@{
        name = $decl.Name
        url = $decl.Url
        rev = $decl.Rev
        commit = $commit
        submodules = [bool]$decl.Submodules
        core_abbrev = [int]$decl.CoreAbbrev
        archive = "git-$($decl.Name).7z"
        sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    })
}

function Get-EntryCommit([string]$Name) {
    $entry = @($sourceEntries | Where-Object { $_.name -eq $Name })[0]
    if (!$entry) { throw "sources.lock has no git entry for '$Name'; add it to sources.psd1 and re-run Download-Sources.ps1." }
    return [string]$entry.commit
}

# A checkout from the cache instead of the network, for the steps below that
# read pinned metadata out of a source tree.
function Get-StagingCheckout([string]$Name) {
    if (!(Test-Path "$repos/$Name/.git")) { Expand-SourceArchive "$SourceCache/git-$Name.7z" $repos }
    return "$repos/$Name"
}

$downloadEntries = [Collections.Generic.List[object]]::new()

# --- ATL VSIX development files (pin = the pinned hash table) --------------
$atl = Get-PinnedAtl
$atlArchive = "$SourceCache/atl.7z"
$atlLocked = Get-LockedDownload $lock 'atl'
$atlPin = Get-PinHash ([ordered]@{ base = $atl.Base; files = $atl.Files })
if (!(Test-PackageSelected 'atl') -and $atlLocked) {
    $downloadEntries.Add($atlLocked)
} elseif (!(Test-DownloadForced 'atl') -and (Test-CachedEntry -Archive $atlArchive -LockedEntry $atlLocked -Pin $atlPin -PinField 'pin')) {
    Write-Host '[SKIP] atl.7z (sources.lock is current)'
    $downloadEntries.Add($atlLocked)
} else {
    if ($Locked) { throw "sources.lock is out of date for 'atl'. Run Download-Sources.ps1 without -Locked, then rebuild." }
    $atlDir = "$files/atl"
    New-Item -ItemType Directory -Force $atlDir | Out-Null
    $atlNames = foreach ($part in $atl.Files.Keys) {
        $file = Get-PinnedAtlFileName $part
        Get-DownloadedFile "$($atl.Base)/$($atl.Files[$part])/$file" "$atlDir/$file" $atl.Files[$part]
        $file
    }
    Compress-SourceArchive $atlArchive $atlDir @($atlNames)
    $downloadEntries.Add([pscustomobject]@{
        name = 'atl'; archive = 'atl.7z'; pin = $atlPin
        sha256 = (Get-FileHash -LiteralPath $atlArchive -Algorithm SHA256).Hash
    })
}

# --- Official prebuilt OBS dependencies (pin = the pinned obs-studio) ------
$obsStudioCommit = Get-EntryCommit 'obs-studio'
$depsArchive = "$SourceCache/official-dependencies.7z"
$depsLocked = Get-LockedDownload $lock 'official-dependencies'
if (!(Test-PackageSelected 'official-dependencies') -and $depsLocked) {
    $downloadEntries.Add($depsLocked)
} elseif (!(Test-DownloadForced 'official-dependencies') -and
          (Test-CachedEntry -Archive $depsArchive -LockedEntry $depsLocked -Pin $obsStudioCommit -PinField 'pin')) {
    Write-Host '[SKIP] official-dependencies.7z (sources.lock is current)'
    $downloadEntries.Add($depsLocked)
} else {
    if ($Locked) { throw "sources.lock is out of date for 'official-dependencies'. Run Download-Sources.ps1 without -Locked, then rebuild." }
    $depsDir = "$files/official-dependencies"
    New-Item -ItemType Directory -Force $depsDir | Out-Null
    $specs = Get-OfficialDependencySpecs (Get-StagingCheckout 'obs-studio')
    foreach ($spec in $specs) { Get-DownloadedFile $spec.Url "$depsDir/$($spec.FileName)" $spec.Hash }
    Compress-SourceArchive $depsArchive $depsDir @($specs.FileName)
    $downloadEntries.Add([pscustomobject]@{
        name = 'official-dependencies'; archive = 'official-dependencies.7z'; pin = $obsStudioCommit
        sha256 = (Get-FileHash -LiteralPath $depsArchive -Algorithm SHA256).Hash
    })
}

# --- Codec source trees (pin = the pinned obs-deps recipes) ----------------
# The obs-deps recipes know where each codec comes from and pin its hash; run
# their Setup stage (download + unpack, no build) and pack the resulting trees.
$obsDepsCommit = Get-EntryCommit 'obs-deps'
$codecArchive = "$SourceCache/codec-sources.7z"
$codecLocked = Get-LockedDownload $lock 'codec-sources'
if (!(Test-PackageSelected 'codec-sources') -and $codecLocked) {
    $downloadEntries.Add($codecLocked)
} elseif (!(Test-DownloadForced 'codec-sources') -and
          (Test-CachedEntry -Archive $codecArchive -LockedEntry $codecLocked -Pin $obsDepsCommit -PinField 'pin')) {
    Write-Host '[SKIP] codec-sources.7z (sources.lock is current)'
    $downloadEntries.Add($codecLocked)
} else {
    if ($Locked) { throw "sources.lock is out of date for 'codec-sources'. Run Download-Sources.ps1 without -Locked, then rebuild." }
    $work = "$staging/codec"
    if (!(Test-Path "$work/obs-deps")) { Expand-SourceArchive "$SourceCache/git-obs-deps.7z" $work }
    Copy-Item "$root/Build-CodecDependencies.ps1" $work -Force
    New-Item -ItemType Directory -Force "$work/repro" | Out-Null
    Copy-Item "$root/repro/UpstreamAdapters.ps1" "$work/repro" -Force
    Push-Location $work
    try { Exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$work/Build-CodecDependencies.ps1" -DownloadOnly } finally { Pop-Location }
    Compress-SourceArchive $codecArchive "$work/build" @('codec-sources')
    $downloadEntries.Add([pscustomobject]@{
        name = 'codec-sources'; archive = 'codec-sources.7z'; pin = $obsDepsCommit
        sha256 = (Get-FileHash -LiteralPath $codecArchive -Algorithm SHA256).Hash
    })
}

$newLock = [pscustomobject]@{
    kind = 'obs-fdk-qsv-sources-lock-v1'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    sources = $sourceEntries.ToArray()
    downloads = $downloadEntries.ToArray()
}
Write-SourceLock $root $newLock | Out-Null
if (!$KeepStaging) { Remove-Item -LiteralPath $staging -Recurse -Force }
Write-Host "Source cache ready: $SourceCache"
Write-Host 'Copy the source-cache directory next to Build-Reproduce.ps1 (or pass -SourceCache) to build offline.'
