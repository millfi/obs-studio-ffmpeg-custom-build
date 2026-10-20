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
#>
[CmdletBinding()]
param(
    [string]$MsysRoot,
    [string]$LLVMRoot,
    [string]$VSInstallPath,
    [string]$SourceCache,
    [switch]$CheckTools,
    [switch]$PrepareOnly
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
function Invoke-Logged([scriptblock]$Action, [string]$LogFile) {
    # One coloured line at a time keeps long builds streaming and leaves the
    # log file free of ANSI escapes.
    & $Action *>&1 | ForEach-Object {
        $text = if ($_ -is [System.Management.Automation.InformationRecord]) { "$($_.MessageData)" } else { "$_" }
        foreach ($line in ($text -split "`r?`n")) {
            if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line }
            Write-LogLine $line
        }
    }
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
    'repro/UpstreamAdapters.ps1',
    'tools/LocalATL.props',
    'verification/CMakeLists.txt',
    'verification/verify-obs.c',
    'verification/Compare-Codecs.ps1',
    'verification/Verify-Package.ps1'
)
. (Join-Path $PSScriptRoot 'repro/BuildEnvironment.ps1')
. (Join-Path $PSScriptRoot 'repro/SourceCache.ps1')
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
function Exec {
    $Command = $args[0]
    $Arguments = @($args | Select-Object -Skip 1)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command $($Arguments -join ' ')" }
}
function Stage([string]$Name, [scriptblock]$Action) {
    Set-Location $WorkRoot
    $stamp = "$WorkRoot/.stages/$Name.json"
    if (Test-Path $stamp) {
        $previous = Get-Content $stamp -Raw | ConvertFrom-Json
        if ($previous.script_sha256 -eq $scriptHash) { Write-LogLine "[SKIP] $Name (completed)"; return }
    }
    Write-LogLine "[BUILD] $Name"
    $log = "$WorkRoot/logs/$Name.log"
    [IO.File]::WriteAllText($log, '')
    Invoke-Logged $Action $log
    @{script_sha256=$scriptHash;completed_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $stamp
}
function Expand-Cache([string]$Name, [string]$Destination) {
    Write-LogLine "[CACHE] $Name -> $Destination" Download
    Expand-SourceArchive "$SourceCache/$Name" $Destination
}
function Assert-CachedFile([string]$Path, [string]$Sha256) {
    # Re-checks the pinned hash of a file restored from the source cache.
    if (!(Test-Path -LiteralPath $Path)) { throw "Missing file restored from the source cache: $Path" }
    if ((Get-FileHash -LiteralPath $Path).Hash -ne $Sha256) { throw "SHA256 mismatch: $Path" }
}
try {
    Stage sources {
        $commits = [ordered]@{}
        foreach ($repo in Get-LockedRepositories $lock) {
            Expand-Cache "git-$($repo.Name).7z" $WorkRoot
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
    Stage atl {
        $atl = Get-PinnedAtl
        Expand-Cache 'atl.7z' "$WorkRoot/downloads"
        foreach ($part in $atl.Files.Keys) {
            $file = Get-PinnedAtlFileName $part
            Assert-CachedFile "$WorkRoot/downloads/$file" $atl.Files[$part]
            Expand-Archive -LiteralPath "downloads/$file" -DestinationPath tools/atl -Force
        }
    }
    Stage official-dependencies {
        Expand-Cache 'official-dependencies.7z' "$WorkRoot/obs-studio/.deps"
        foreach ($dep in (Get-OfficialDependencySpecs "$WorkRoot/obs-studio")) {
            Assert-CachedFile "$WorkRoot/obs-studio/.deps/$($dep.FileName)" $dep.Hash
            $target = "$WorkRoot/obs-studio/.deps/$($dep.Destination)"
            New-Item -ItemType Directory -Force $target | Out-Null
            Push-Location $target
            try { Exec cmake -E tar xf "$WorkRoot/obs-studio/.deps/$($dep.FileName)" } finally { Pop-Location }
            [IO.File]::WriteAllText("$WorkRoot/obs-studio/.deps/.dependency_$($dep.Kind)_$($dep.Arch).sha256", $dep.Hash)
        }
        $stock = "$WorkRoot/obs-studio/.deps/obs-deps-2026-08-26-x64/bin/ffmpeg.exe"
        foreach ($kind in @('encoders','decoders','filters','formats','protocols','buildconf')) {
            & $stock -hide_banner "-$kind" *> "verification/stock-$kind.txt"
            if ($LASTEXITCODE) { throw "Stock FFmpeg query failed: $kind" }
        }
    }
    Stage ffmpeg-patches {
        Get-ChildItem "$WorkRoot/obs-deps/utils.pwsh/*.ps1" | ForEach-Object { . $_.FullName }
        . "$WorkRoot/obs-deps/deps.ffmpeg/99-ffmpeg.ps1"
        Push-Location ffmpeg
        try { foreach ($item in $Patches) { Safe-Patch @item } } finally { Pop-Location }
    }
    if ($PrepareOnly) { Write-LogLine "Preparation complete: $WorkRoot"; return }
    Stage fdk {
        Exec cmake -S fdk-aac -B build/fdk -G 'Visual Studio 18 2026' -A x64 -DBUILD_SHARED_LIBS=OFF "-DCMAKE_INSTALL_PREFIX=$WorkRoot/local"
        Exec cmake --build build/fdk --config Release --parallel 6
        Exec cmake --install build/fdk --config Release
    }
    Stage vpl {
        Exec cmake -S libvpl -B build/vpl -G 'Visual Studio 18 2026' -A x64 -DBUILD_SHARED_LIBS=OFF -DINSTALL_EXAMPLES=OFF "-DCMAKE_INSTALL_PREFIX=$WorkRoot/local"
        Exec cmake --build build/vpl --config Release --parallel 6
        Exec cmake --install build/vpl --config Release
    }
    Stage codec-sources {
        # Source trees downloaded by Download-Sources.ps1 through the obs-deps
        # recipes; the codec builds below start at their Patch stage.
        Expand-Cache 'codec-sources.7z' "$WorkRoot/build"
    }
    foreach ($codec in @('opus','libogg','libvorbis','libvpx','svt-av1','aom','lame')) {
        Stage "codec-$codec" { Exec pwsh -NoProfile -File "$WorkRoot/Build-CodecDependencies.ps1" -SkipSetup -Dependencies $codec }
    }
    Stage obs { Exec pwsh -NoProfile -File "$WorkRoot/Build-OBS.ps1" }
    Stage ffmpeg { Exec pwsh -NoProfile -File "$WorkRoot/Build-FFmpeg.ps1" }
    # Packaging and validation always run; they are intentionally not skipped on resume.
    Invoke-Logged { Exec pwsh -NoProfile -File "$WorkRoot/Package-OBS.ps1" }
    Invoke-Logged { Exec cmake -S verification -B build/verification -G 'Visual Studio 18 2026' -A x64 }
    Invoke-Logged { Exec cmake --build build/verification --config Release --parallel 4 }
    Invoke-Logged { Exec pwsh -NoProfile -File "$WorkRoot/verification/Verify-Package.ps1" }
    $package = "$WorkRoot/OBS-Studio-FDK-QSV"
    if (!(Test-Path "$package/portable_mode") -or (Get-Item "$package/portable_mode").Length -ne 0) { throw 'Portable marker validation failed.' }
    New-Item -ItemType Directory -Force "$package/build-info", "$package/licenses/fdk-aac" | Out-Null
    Copy-Item verification/source-commits.json,verification/build-tools.json,verification/encoders-diff.json,verification/decoders-diff.json "$package/build-info" -Force
    Copy-Item fdk-aac/NOTICE "$package/licenses/fdk-aac/NOTICE" -Force
    Write-LogLine "SUCCESS: $package/Start-OBS.cmd"
    Write-LogLine 'QSV/NVENC/AMF encoders are registered. Actual encoding requires a compatible GPU and driver; no hardware success is inferred.' Warning
} finally {
    Set-Location $oldLocation
    Set-ConsoleEncoding $originalConsoleEncoding $originalCodePage
}

