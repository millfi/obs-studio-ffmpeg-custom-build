<#
.SYNOPSIS
Build the pinned Windows x64 OBS + FDK AAC + FFmpeg QSV portable distribution.
.DESCRIPTION
Multi-file source layout: keep this script and the extracted source files together.
Downloads source/development dependencies, never installs system tools. Existing unrelated
directories are refused. Re-run with the same WorkRoot to resume completed stages.
The resulting program/configuration is reproduced, not a byte-for-byte reproducible binary.
#>
[CmdletBinding()]
param(
    [string]$WorkRoot = (Join-Path $PSScriptRoot 'repro-build'),
    [string]$MsysRoot,
    [string]$LLVMRoot,
    [string]$VSInstallPath,
    [switch]$CheckTools,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
# Reviewable source files live alongside this entry point. They are copied into
# WorkRoot so the original build scripts retain their PSScriptRoot semantics.
$PayloadFiles = @(
    'Build-OBS.ps1',
    'Build-FFmpeg.ps1',
    'Build-CodecDependencies.ps1',
    'Package-OBS.ps1',
    'repro/BuildEnvironment.ps1',
    'repro/UpstreamAdapters.ps1',
    'tools/LocalATL.props',
    'verification/CMakeLists.txt',
    'verification/verify-obs.c',
    'verification/Compare-Codecs.ps1',
    'verification/Verify-Package.ps1'
)
. (Join-Path $PSScriptRoot 'repro/BuildEnvironment.ps1')
$tools = Get-BuildEnvironment -MsysRoot $MsysRoot -LLVMRoot $LLVMRoot -VSInstallPath $VSInstallPath
Write-Host 'Required build tools: PASS'
if ($CheckTools) {
    $tools | Select-Object MsysRoot, LLVMRoot, MSVC, SDKRoot | Format-List
    return
}
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot).Replace('\','/')
if ($WorkRoot -notmatch '^[A-Za-z]:/[A-Za-z0-9_./-]+$') { throw 'Use a local ASCII work path without spaces, for example -WorkRoot C:/obs-repro. The upstream FFmpeg/obs-deps recipes require this.' }
if (Test-Path $WorkRoot) {
    if (!(Test-Path "$WorkRoot/.obs-repro-owned.json") -and @(Get-ChildItem $WorkRoot -Force).Count) { throw "WorkRoot must be empty or previously created by this script: $WorkRoot" }
}
# Preserve the original resume behaviour while tracking edits to *any* source
# file. A change to a payload invalidates the completed-stage stamps.
$fingerprintLines = @(
    'entry-point|{0}' -f (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
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
        if ($previous.script_sha256 -eq $scriptHash) { Write-Host "[SKIP] $Name (completed)"; return }
    }
    Write-Host "[BUILD] $Name"
    & $Action *>&1 | Tee-Object -FilePath "$WorkRoot/logs/$Name.log"
    @{script_sha256=$scriptHash;completed_utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content $stamp
}
function Source([string]$Name, [string]$Url, [string]$Commit) {
    if (!(Test-Path "$Name/.git")) { Exec git init $Name }
    if ('origin' -notin @(& git -C $Name remote)) { Exec git -C $Name remote add origin $Url }
    $head = & git -C $Name rev-parse --verify HEAD 2>$null
    if ($head -ne $Commit) {
        if ($head) { throw "Refusing to overwrite existing $Name commit $head (expected $Commit)." }
        Exec git -C $Name fetch --depth 1 origin $Commit
        Exec git -C $Name checkout --detach $Commit
    }
    if ((& git -C $Name rev-parse HEAD) -ne $Commit) { throw "Commit verification failed: $Name" }
}
function Download([string]$Url, [string]$Path, [string]$Sha256) {
    if (!(Test-Path $Path)) {
        Invoke-WebRequest -Uri $Url -OutFile "$Path.partial" -MaximumRetryCount 3
        if ((Get-FileHash "$Path.partial").Hash -ne $Sha256) { throw "SHA256 mismatch: $Url" }
        Move-Item -LiteralPath "$Path.partial" -Destination $Path
    }
    if ((Get-FileHash $Path).Hash -ne $Sha256) { throw "Cached SHA256 mismatch: $Path" }
}
try {
    Stage sources {
        Source obs-studio https://github.com/obsproject/obs-studio.git b5bfb79093e26ce4b0e71d999f59b6b22f961121
        Exec git -C obs-studio submodule update --init --recursive
        # Include the nearest tag so OBS derives exactly the same version string.
        Exec git -C obs-studio fetch --depth 200 origin tag 32.2.1
        Exec git -C obs-studio fetch --deepen 200 origin b5bfb79093e26ce4b0e71d999f59b6b22f961121
        Exec git -C obs-studio config core.abbrev 9
        Source fdk-aac https://github.com/mstorsjo/fdk-aac.git 7c83d08002332b2730c845eec3497e6bf585dd28
        Source ffmpeg https://github.com/FFmpeg/FFmpeg.git 38b88335f99e76ed89ff3c93f877fdefce736c13
        Exec git -C ffmpeg fetch --depth 1 origin tag n8.1.2
        Source obs-deps https://github.com/obsproject/obs-deps.git f80e1d30181b0ff2b048b6d8fe8b8c501f3d221c
        Source libvpl https://github.com/intel/libvpl.git 674d015bcb294bc39fa276e99a652ea045423e82
        $commits = [ordered]@{}
        foreach ($repo in @('obs-studio','fdk-aac','ffmpeg','obs-deps','libvpl')) { $commits[$repo] = & git -C $repo rev-parse HEAD }
        $commits | ConvertTo-Json | Set-Content verification/source-commits.json
    }
    Stage atl {
        $base = 'https://download.visualstudio.microsoft.com/download/pr/a62262cf-b9f6-4770-9454-7372ad8fcec0'
        $hashes = @{
            Headers='df87bd5da5bb3d101ca8238cc4d5f90d648336202c41f2ab80b5549b7ac495d1'
            X64='6bf1c9950675fe9e5f46d861663ae19abcd18ce8e28602675194c32550ab3b04'
            X86='935a0f126b0c5a1f356103dabd2c8b6c74a1f6fa8292982ff7e8a4230d86fb50'
        }
        foreach ($part in $hashes.Keys) {
            $file = "Microsoft.VC.14.51.ATL.$part.base.vsix"
            Download "$base/$($hashes[$part])/$file" "downloads/$file" $hashes[$part]
            Expand-Archive -LiteralPath "downloads/$file" -DestinationPath tools/atl -Force
        }
    }
    Stage official-dependencies {
        $presets = Get-Content obs-studio/CMakePresets.json -Raw | ConvertFrom-Json
        $dependencies = ($presets.configurePresets | Where-Object name -eq dependencies).vendor.'obsproject.com/obs-studio'.dependencies
        $specs = @(
            @('prebuilt','x64','windows-deps-{0}-x64.zip','obs-deps-{0}-x64'),
            @('prebuilt','x86','windows-deps-{0}-x86.zip','obs-deps-{0}-x86'),
            @('qt6','x64','windows-deps-qt6-{0}-x64.zip','obs-deps-qt6-{0}-x64'),
            @('cef','x64','cef_binary_{0}_windows_x64.zip','cef_binary_{0}_windows_x64')
        )
        New-Item -ItemType Directory -Force obs-studio/.deps | Out-Null
        foreach ($spec in $specs) {
            $dep = $dependencies.($spec[0]); $arch = $spec[1]
            $filename = $spec[2] -f $dep.version; $destination = $spec[3] -f $dep.version
            $url = if ($spec[0] -eq 'cef') { "$($dep.baseUrl)/$filename" } else { "$($dep.baseUrl)/$($dep.version)/$filename" }
            $hash = $dep.hashes."windows-$arch"
            Download $url "obs-studio/.deps/$filename" $hash
            $target = "$WorkRoot/obs-studio/.deps/$destination"
            New-Item -ItemType Directory -Force $target | Out-Null
            Push-Location $target
            try { Exec cmake -E tar xf "$WorkRoot/obs-studio/.deps/$filename" } finally { Pop-Location }
            [IO.File]::WriteAllText("$WorkRoot/obs-studio/.deps/.dependency_$($spec[0])_$arch.sha256", $hash)
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
    if ($PrepareOnly) { Write-Host "Preparation complete: $WorkRoot"; return }
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
    foreach ($codec in @('opus','libogg','libvorbis','libvpx','svt-av1','aom','lame')) {
        Stage "codec-$codec" { Exec pwsh -NoProfile -File "$WorkRoot/Build-CodecDependencies.ps1" -Dependencies $codec }
    }
    Stage obs { Exec pwsh -NoProfile -File "$WorkRoot/Build-OBS.ps1" }
    Stage ffmpeg { Exec pwsh -NoProfile -File "$WorkRoot/Build-FFmpeg.ps1" }
    # Packaging and validation always run; they are intentionally not skipped on resume.
    Exec pwsh -NoProfile -File "$WorkRoot/Package-OBS.ps1"
    Exec cmake -S verification -B build/verification -G 'Visual Studio 18 2026' -A x64
    Exec cmake --build build/verification --config Release --parallel 4
    Exec pwsh -NoProfile -File "$WorkRoot/verification/Verify-Package.ps1"
    $package = "$WorkRoot/OBS-Studio-FDK-QSV"
    if (!(Test-Path "$package/portable_mode") -or (Get-Item "$package/portable_mode").Length -ne 0) { throw 'Portable marker validation failed.' }
    New-Item -ItemType Directory -Force "$package/build-info", "$package/licenses/fdk-aac" | Out-Null
    Copy-Item verification/source-commits.json,verification/build-tools.json,verification/encoders-diff.json,verification/decoders-diff.json "$package/build-info" -Force
    Copy-Item fdk-aac/NOTICE "$package/licenses/fdk-aac/NOTICE" -Force
    Write-Host "SUCCESS: $package/Start-OBS.cmd"
    Write-Host 'QSV/NVENC/AMF encoders are registered. Actual encoding requires a compatible GPU and driver; no hardware success is inferred.'
} finally { Set-Location $oldLocation }

