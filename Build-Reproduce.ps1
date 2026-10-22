<#
.SYNOPSIS
Build the pinned Windows x64 OBS + FDK AAC + FFmpeg QSV portable distribution.
.DESCRIPTION
Multi-file source layout: keep this script and the extracted source files together.
Runs fully offline: every source and development dependency is read from the
source cache (./source-cache by default) that Download-Sources.ps1 filled with
7-Zip (Zstandard) archives on a networked machine. No tools are ever installed.
Everything is generated in ./work next to this script, which is git-ignored;
re-run the script to resume completed stages. The resulting
program/configuration is reproduced, not a byte-for-byte reproducible binary.

Stages run concurrently wherever their inputs allow (repro/ParallelTasks.ps1):
the small libraries (fdk, vpl, the codecs) build alongside each other and OBS
builds while FFmpeg builds; only real dependencies order them (libvorbis after
libogg, OBS after fdk/ATL/prebuilt deps, FFmpeg after every library and its
patches). -ThrottleLimit caps how many stages run at the same time.
#>
[CmdletBinding()]
param(
    [string]$MsysRoot,
    [string]$LLVMRoot,
    [string]$VSInstallPath,
    [string]$SourceCache,
    [switch]$CheckTools,
    [switch]$PrepareOnly,
    [int]$ThrottleLimit
)
$ErrorActionPreference = 'Stop'
function Set-ConsoleEncoding([System.Text.Encoding]$Encoding, [int]$CodePage) {
    # chcp also changes the code page that child processes inherit, which is
    # what makes the nested "pwsh -Command" from Invoke-DevShell decode MSBuild
    # output as UTF-8; the .NET setter only affects this process.
    try { [Console]::OutputEncoding = $Encoding } catch { }
    try { & chcp.com $CodePage *> $null } catch { }
}
# MSBuild, CMake and vswhere write UTF-8, while a Japanese Windows console
# defaults to CP932 and PowerShell decodes native output with the console code
# page; their Japanese messages would then reach the terminal and logs/ as
# mojibake and the vswhere JSON would not even parse. Pin the console to UTF-8
# before the first tool runs and restore the original setting at the end.
$originalConsoleEncoding = [Console]::OutputEncoding
$originalCodePage = 0
try { $originalCodePage = [int]((& chcp.com) -replace '[^\d]', '') } catch { }
if ($originalCodePage -le 0) { $originalCodePage = $originalConsoleEncoding.CodePage }
Set-ConsoleEncoding ([System.Text.UTF8Encoding]::new()) 65001
# Console log colours (24-bit RGB). stderr of the build tools arrives as error
# records and would render red even when it is only progress output, so every
# log line is re-emitted through Write-LogLine and coloured by category:
# downloads #0969DA, normal output #58606D, warnings #9A6700. Only lines that
# really report a failure stay red (#CF222E).
$ansi = [char]27
$script:LogColors = @{
    Download = "$ansi[38;2;9;105;218m"   # #0969DA
    Normal   = "$ansi[38;2;88;96;109m"   # #58606D
    Warning  = "$ansi[38;2;154;103;0m"   # #9A6700
    Error    = "$ansi[38;2;207;34;46m"   # #CF222E
}
function Get-LogKind([string]$Line) {
    if ($Line -match '(?i)(^\s*(error|fatal|failed|failure)\b|:\s*error\b|\berror [A-Z]{1,5}\d+|\berror\s+\d+\s*$|エラー|失敗)') { return 'Error' }
    if ($Line -match '(?i)(warning(?!\s*\(s\))|警告)') { return 'Warning' }
    if ($Line -match '(?i)(\[download\]|cloning into|remote:|from https?://|counting objects|compressing objects|enumerating objects|receiving objects|resolving deltas|unpacking objects|(?<![\\/])download|fetch)') { return 'Download' }
    return 'Normal'
}
function Write-LogLine([string]$Line, [string]$Kind) {
    if (!$Kind) { $Kind = Get-LogKind $Line }
    Write-Host "$($script:LogColors[$Kind])$Line$ansi[0m"
}
# The only build output location. Keeping it fixed means the scripts below can
# never be pointed at a directory that is tracked by git.
$WorkRoot = Join-Path $PSScriptRoot 'work'
# Reviewable source files live alongside this entry point. They are copied into
# WorkRoot so the original build scripts retain their PSScriptRoot semantics.
$PayloadFiles = @(
    'Build-OBS.ps1',
    'Build-FFmpeg.ps1',
    'Build-CodecDependencies.ps1',
    'Package-OBS.ps1',
    'repro/BuildEnvironment.ps1',
    'repro/SourceCache.ps1',
    'repro/ParallelTasks.ps1',
    'repro/UpstreamAdapters.ps1',
    'tools/LocalATL.props',
    'verification/CMakeLists.txt',
    'verification/verify-obs.c',
    'verification/Compare-Codecs.ps1',
    'verification/Verify-Package.ps1'
)
. (Join-Path $PSScriptRoot 'repro/BuildEnvironment.ps1')
. (Join-Path $PSScriptRoot 'repro/SourceCache.ps1')
. (Join-Path $PSScriptRoot 'repro/ParallelTasks.ps1')
Get-SevenZip | Out-Null
$tools = Get-BuildEnvironment -MsysRoot $MsysRoot -LLVMRoot $LLVMRoot -VSInstallPath $VSInstallPath
Write-LogLine 'Required build tools: PASS'
if ($CheckTools) {
    $tools | Select-Object MsysRoot, LLVMRoot, MSVC, SDKRoot | Format-List
    Set-ConsoleEncoding $originalConsoleEncoding $originalCodePage
    return
}
if (!$SourceCache) { $SourceCache = Join-Path $PSScriptRoot 'source-cache' }
$SourceCache = [IO.Path]::GetFullPath($SourceCache)
$lock = Test-SourceLock $PSScriptRoot $SourceCache
Write-LogLine "Sources lock: PASS ($(@($lock.sources).Count) sources, $(@($lock.downloads).Count) downloads, $SourceCache)"
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot).Replace('\','/')
if ($WorkRoot -notmatch '^[A-Za-z]:/[A-Za-z0-9_./-]+$') { throw "The build path must be local, ASCII and space-free (the upstream FFmpeg/obs-deps recipes require it): $WorkRoot. Move the checkout to such a path." }
if (Test-Path $WorkRoot) {
    if (!(Test-Path "$WorkRoot/.obs-repro-owned.json") -and @(Get-ChildItem $WorkRoot -Force).Count) { throw "Refusing to write into a non-empty directory that this script did not create: $WorkRoot" }
}
# Preserve the original resume behaviour while tracking edits to *any* source
# file. A change to a payload invalidates the completed-stage stamps. The build
# never reads sources.psd1: sources.lock is the contract with the download step,
# so its hash belongs in the fingerprint.
$lockPath = Get-SourceLockPath $PSScriptRoot
if (!(Test-Path -LiteralPath $lockPath)) {
    throw "sources.lock is missing: $lockPath. Run Download-Sources.ps1 on a networked machine first."
}
$fingerprintLines = @(
    'entry-point|{0}' -f (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    'sources.lock|{0}' -f (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
    foreach ($relative in ($PayloadFiles | Sort-Object -Unique)) {
        $sourcePath = Join-Path $PSScriptRoot $relative
        if (!(Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Missing source file: $sourcePath. Keep the extracted files alongside the entry script."
        }
        '{0}|{1}' -f $relative, (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    }
)
$scriptHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes(($fingerprintLines -join "`n"))
    )
)
New-Item -ItemType Directory -Force $WorkRoot | Out-Null
$marker = "$WorkRoot/.obs-repro-owned.json"
if (Test-Path $marker) {
    $owner = Get-Content $marker -Raw | ConvertFrom-Json
    if ($owner.kind -ne 'obs-fdk-qsv-repro-v1') { throw 'Unrecognized workspace ownership marker.' }
}
@{kind='obs-fdk-qsv-repro-v1';script_sha256=$scriptHash} | ConvertTo-Json | Set-Content $marker
foreach ($relative in $PayloadFiles) {
    $path = Join-Path $WorkRoot $relative
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $path -Force
}
Enable-BuildEnvironment $tools
New-Item -ItemType Directory -Force "$WorkRoot/logs", "$WorkRoot/.stages", "$WorkRoot/downloads", "$WorkRoot/verification" | Out-Null
$tools | ConvertTo-Json -Depth 6 | Set-Content "$WorkRoot/verification/build-tools.json"
$oldLocation = Get-Location
Set-Location $WorkRoot
try {
if ($ThrottleLimit -lt 1) { $ThrottleLimit = [Math]::Max(2, [int][Math]::Ceiling([Environment]::ProcessorCount / 2)) }
# --- Parallel stage graph ---------------------------------------------------
# Every stage body runs in its own thread job (repro/ParallelTasks.ps1), so
# independent stages overlap: the small libraries build alongside each other
# and OBS builds while FFmpeg builds. Only real dependencies order them; each
# job's output goes to logs/<stage>.log and to the console, prefixed with the
# stage name. The prelude rebuilds the small helper environment the bodies use.
$shared = [pscustomobject]@{ WorkRoot = $WorkRoot; SourceCache = $SourceCache; Lock = $lock }
$taskPrelude = {
    $ErrorActionPreference = 'Stop'
    Set-Location $Shared.WorkRoot
    . "$($Shared.WorkRoot)/repro/SourceCache.ps1"
    function Expand-Cache([string]$Name, [string]$Destination) {
        Write-Output "[CACHE] $Name -> $Destination"
        Expand-SourceArchive "$($Shared.SourceCache)/$Name" $Destination
    }
    function Assert-CachedFile([string]$Path, [string]$Sha256) {
        # Re-checks the pinned hash of a file restored from the source cache.
        if (!(Test-Path -LiteralPath $Path)) { throw "Missing file restored from the source cache: $Path" }
        if ((Get-FileHash -LiteralPath $Path).Hash -ne $Sha256) { throw "SHA256 mismatch: $Path" }
    }
}.ToString()
$sourcesBody = {
    $commits = [ordered]@{}
    foreach ($repo in Get-LockedRepositories $Shared.Lock) {
        Expand-Cache "git-$($repo.Name).7z" $Shared.WorkRoot
        $head = & git -C $repo.Name rev-parse HEAD
        if ($head -ne $repo.Commit) { throw "Source cache commit mismatch: $($repo.Name) is $head, expected $($repo.Commit)." }
        if ($repo.CoreAbbrev) { Exec git -C $repo.Name config core.abbrev $repo.CoreAbbrev }
        $commits[$repo.Name] = $head
    }
    # Offline integrity check: every submodule must be checked out at the
    # commit the pinned obs-studio tree records.
    $submodules = & git -C obs-studio submodule status --recursive
    if ($LASTEXITCODE) { throw 'git submodule status failed' }
    $bad = @($submodules | Where-Object { $_ -match '^[+-U]' })
    if ($bad.Count) { throw "obs-studio submodules are not fully checked out in the source cache:`n$($bad -join "`n")" }
    $commits | ConvertTo-Json | Set-Content verification/source-commits.json
}
$atlBody = {
    $atl = Get-PinnedAtl
    Expand-Cache 'atl.7z' "$($Shared.WorkRoot)/downloads"
    foreach ($part in $atl.Files.Keys) {
        $file = Get-PinnedAtlFileName $part
        Assert-CachedFile "$($Shared.WorkRoot)/downloads/$file" $atl.Files[$part]
        Expand-Archive -LiteralPath "downloads/$file" -DestinationPath tools/atl -Force
    }
}
$officialDependenciesBody = {
    Expand-Cache 'official-dependencies.7z' "$($Shared.WorkRoot)/obs-studio/.deps"
    foreach ($dep in (Get-OfficialDependencySpecs "$($Shared.WorkRoot)/obs-studio")) {
        Assert-CachedFile "$($Shared.WorkRoot)/obs-studio/.deps/$($dep.FileName)" $dep.Hash
        $target = "$($Shared.WorkRoot)/obs-studio/.deps/$($dep.Destination)"
        New-Item -ItemType Directory -Force $target | Out-Null
        Push-Location $target
        try { Exec cmake -E tar xf "$($Shared.WorkRoot)/obs-studio/.deps/$($dep.FileName)" } finally { Pop-Location }
        [IO.File]::WriteAllText("$($Shared.WorkRoot)/obs-studio/.deps/.dependency_$($dep.Kind)_$($dep.Arch).sha256", $dep.Hash)
    }
    $stock = "$($Shared.WorkRoot)/obs-studio/.deps/obs-deps-2026-08-26-x64/bin/ffmpeg.exe"
    foreach ($kind in @('encoders','decoders','filters','formats','protocols','buildconf')) {
        & $stock -hide_banner "-$kind" *> "verification/stock-$kind.txt"
        if ($LASTEXITCODE) { throw "Stock FFmpeg query failed: $kind" }
    }
}
$ffmpegPatchesBody = {
    Get-ChildItem "$($Shared.WorkRoot)/obs-deps/utils.pwsh/*.ps1" | ForEach-Object { . $_.FullName }
    . "$($Shared.WorkRoot)/obs-deps/deps.ffmpeg/99-ffmpeg.ps1"
    Push-Location ffmpeg
    try { foreach ($item in $Patches) { Safe-Patch @item } } finally { Pop-Location }
}
$fdkBody = {
    Exec cmake -S fdk-aac -B build/fdk -G 'Visual Studio 18 2026' -A x64 -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$($Shared.WorkRoot)/local"
    Exec cmake --build build/fdk --config Release --parallel 6
    Exec cmake --install build/fdk --config Release
}
$vplBody = {
    Exec cmake -S libvpl -B build/vpl -G 'Visual Studio 18 2026' -A x64 -DBUILD_SHARED_LIBS=OFF -DINSTALL_EXAMPLES=OFF "-DCMAKE_INSTALL_PREFIX=$($Shared.WorkRoot)/local"
    Exec cmake --build build/vpl --config Release --parallel 6
    Exec cmake --install build/vpl --config Release
}
$codecSourcesBody = {
    # Source trees downloaded by Download-Sources.ps1 through the obs-deps
    # recipes; the codec builds below start at their Patch stage.
    Expand-Cache 'codec-sources.7z' "$($Shared.WorkRoot)/build"
}
$codecBody = {
    param($Codec)
    Exec pwsh -NoProfile -File "$($Shared.WorkRoot)/Build-CodecDependencies.ps1" -SkipSetup -Dependencies $Codec
}
$obsBody = { Exec pwsh -NoProfile -File "$($Shared.WorkRoot)/Build-OBS.ps1" }
$ffmpegBody = { Exec pwsh -NoProfile -File "$($Shared.WorkRoot)/Build-FFmpeg.ps1" }
# Packaging and validation always run; they are intentionally not skipped on
# resume, so this stage is in $alwaysRun below.
$finalizeBody = {
    Exec pwsh -NoProfile -File "$($Shared.WorkRoot)/Package-OBS.ps1"
    Exec cmake -S verification -B build/verification -G 'Visual Studio 18 2026' -A x64
    Exec cmake --build build/verification --config Release --parallel 4
    Exec pwsh -NoProfile -File "$($Shared.WorkRoot)/verification/Verify-Package.ps1"
    $package = "$($Shared.WorkRoot)/OBS-Studio-FDK-QSV"
    if (!(Test-Path "$package/portable_mode") -or (Get-Item "$package/portable_mode").Length -ne 0) { throw 'Portable marker validation failed.' }
    New-Item -ItemType Directory -Force "$package/build-info", "$package/licenses/fdk-aac" | Out-Null
    Copy-Item verification/source-commits.json,verification/build-tools.json,verification/encoders-diff.json,verification/decoders-diff.json "$package/build-info" -Force
    Copy-Item fdk-aac/NOTICE "$package/licenses/fdk-aac/NOTICE" -Force
}
$graph = [ordered]@{
    sources = @{ Depends = @(); Body = $sourcesBody; Args = @() }
    atl = @{ Depends = @('sources'); Body = $atlBody; Args = @() }
    'official-dependencies' = @{ Depends = @('sources'); Body = $officialDependenciesBody; Args = @() }
    'ffmpeg-patches' = @{ Depends = @('sources'); Body = $ffmpegPatchesBody; Args = @() }
    fdk = @{ Depends = @('sources'); Body = $fdkBody; Args = @() }
    vpl = @{ Depends = @('sources'); Body = $vplBody; Args = @() }
    'codec-sources' = @{ Depends = @('sources'); Body = $codecSourcesBody; Args = @() }
}
foreach ($codec in @('opus', 'libogg', 'libvorbis', 'libvpx', 'svt-av1', 'aom', 'lame')) {
    # libvorbis links against the ogg that codec-libogg installs into local/.
    $depends = @('codec-sources') + @(if ($codec -eq 'libvorbis') { 'codec-libogg' })
    $graph["codec-$codec"] = @{ Depends = $depends; Body = $codecBody; Args = @($codec) }
}
$graph['obs'] = @{ Depends = @('atl', 'official-dependencies', 'fdk'); Body = $obsBody; Args = @() }
$graph['ffmpeg'] = @{
    Depends = @('official-dependencies', 'ffmpeg-patches', 'fdk', 'vpl') + @(foreach ($codec in @('opus', 'libogg', 'libvorbis', 'libvpx', 'svt-av1', 'aom', 'lame')) { "codec-$codec" })
    Body = $ffmpegBody
    Args = @()
}
$graph['finalize'] = @{ Depends = @('obs', 'ffmpeg'); Body = $finalizeBody; Args = @() }
$alwaysRun = @('finalize')
if ($PrepareOnly) {
    foreach ($name in @('fdk', 'vpl', 'codec-sources', 'obs', 'ffmpeg', 'finalize') + @(foreach ($codec in @('opus', 'libogg', 'libvorbis', 'libvpx', 'svt-av1', 'aom', 'lame')) { "codec-$codec" })) {
        $graph.Remove($name)
    }
}
# Completed stages stay completed: drop them (and the edges into them) when
# their stamp matches the current script hash.
$skipped = @{}
foreach ($name in @($graph.Keys)) {
    $stamp = "$WorkRoot/.stages/$name.json"
    if ($name -notin $alwaysRun -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw | ConvertFrom-Json).script_sha256 -eq $scriptHash)) {
        Write-LogLine "[SKIP] $name (completed)"
        $skipped[$name] = $true
        $graph.Remove($name)
    }
}
foreach ($task in $graph.Values) {
    $task.Depends = @($task.Depends | Where-Object { $_ -notin $skipped.Keys })
}
$onLine = {
    param($task, $line)
    Add-Content -LiteralPath "$WorkRoot/logs/$task.log" -Value $line
    Write-LogLine "[$task] $line"
}
$onTaskEvent = {
    param($task, $event, $detail)
    if ($event -eq 'start') {
        [IO.File]::WriteAllText("$WorkRoot/logs/$task.log", '')
        Write-LogLine "[BUILD] $task"
    } elseif ($event -eq 'completed') {
        if ($task -notin $alwaysRun) {
            @{script_sha256=$scriptHash;completed_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content "$WorkRoot/.stages/$task.json"
        }
        Write-LogLine "[ OK ] $task ($([int][Math]::Ceiling($detail.TotalSeconds))s)"
    } else {
        Write-LogLine "[FAIL] $task : $detail" Error
    }
}
$run = $null
if ($graph.Count) {
    $run = Invoke-TaskGraph -Tasks $graph -Prelude $taskPrelude -Shared $shared -ThrottleLimit $ThrottleLimit `
        -OnLine $onLine -OnTaskEvent $onTaskEvent
}
if ($PrepareOnly) { Write-LogLine "Preparation complete: $WorkRoot"; return }
$package = "$WorkRoot/OBS-Studio-FDK-QSV"
Write-LogLine "SUCCESS: $package/Start-OBS.cmd"
Write-LogLine 'QSV/NVENC/AMF encoders are registered. Actual encoding requires a compatible GPU and driver; no hardware success is inferred.' Warning
if ($run) { Write-LogLine "Stages ran in $([int]$run.Elapsed.TotalSeconds)s (throttle $ThrottleLimit)" }
} finally {
    Set-Location $oldLocation
    Set-ConsoleEncoding $originalConsoleEncoding $originalCodePage
}

