# Shared source-cache support for Download-Sources.ps1 (online) and
# Build-Reproduce.ps1 (offline).
#
# Version handling follows the Cargo model:
#   sources.psd1    human-edited declarations (tag / branch / commit), repo root
#   sources.lock    generated: resolved commits + archive SHA256, repo root
#   source-cache/   the 7-Zip (Zstandard) archives themselves (not version controlled)
# Download-Sources.ps1 resolves the declarations and writes the lock; the build
# reads only the lock, so it stays offline, deterministic and independent of
# what the declarations currently say.

# ---------------------------------------------------------------------------
# 7-Zip with Zstandard
# ---------------------------------------------------------------------------

function Get-SevenZip {
    # Packing needs Zstandard and so does extraction, so both scripts require
    # the same zstd-capable 7z (e.g. 7-Zip ZS) instead of stock 7-Zip.
    $sevenZip = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if (!$sevenZip) { throw '7z.exe must be on PATH. Use a Zstandard-capable 7-Zip build (e.g. 7-Zip ZS).' }
    $info = & $sevenZip.Source i 2>&1 | Out-String
    if ($LASTEXITCODE) { throw "7z i failed ($LASTEXITCODE): $($sevenZip.Source)" }
    $codecs = [regex]::Match($info, '(?s)Codecs:(.*)$').Groups[1].Value
    if ($codecs -notmatch '\bZSTD\b') { throw "7z at $($sevenZip.Source) has no ZSTD codec. Use a Zstandard-capable 7-Zip build (e.g. 7-Zip ZS)." }
    return $sevenZip.Source
}

# ---------------------------------------------------------------------------
# Declarations (sources.psd1)
# ---------------------------------------------------------------------------

function Get-DefaultSourceUrls {
    # Repositories a declaration may name without repeating its URL.
    [ordered]@{
        'obs-studio' = 'https://github.com/obsproject/obs-studio.git'
        'fdk-aac' = 'https://github.com/mstorsjo/fdk-aac.git'
        'ffmpeg' = 'https://github.com/FFmpeg/FFmpeg.git'
        'obs-deps' = 'https://github.com/obsproject/obs-deps.git'
        'libvpl' = 'https://github.com/intel/libvpl.git'
    }
}

function Get-DeclaredRepositories {
    param([string]$Root)
    $path = Join-Path $Root 'sources.psd1'
    if (!(Test-Path -LiteralPath $path)) { throw "Version declarations not found: $path" }
    $declarations = (Import-PowerShellDataFile -LiteralPath $path).sources
    if (!$declarations) { throw "sources.psd1 must define a 'sources' table." }
    $defaults = Get-DefaultSourceUrls
    foreach ($name in ($declarations.Keys | Sort-Object)) {
        $entry = $declarations[$name]
        if ($entry -is [string]) { $entry = @{ rev = $entry } }
        if (!$entry.rev) { throw "sources.psd1: '$name' needs a rev (tag, branch or 40-character commit)." }
        $url = if ($entry.url) { [string]$entry.url }
               elseif ($defaults.Contains($name)) { $defaults[$name] }
               else { throw "sources.psd1: '$name' needs an explicit url." }
        [pscustomobject]@{
            Name = $name
            Url = $url
            Rev = [string]$entry.rev
            Submodules = [bool]$entry.submodules
            History = [int]$entry.history
            Tags = if ($entry.tags) { @($entry.tags | ForEach-Object { [string]$_ }) } else { @() }
            CoreAbbrev = [int]$entry.core_abbrev
        }
    }
}

function Resolve-GitCommit {
    # A 40-character commit is used as-is (no network). Anything else is
    # resolved through ls-remote: a tag (annotated tags are peeled to their
    # commit) or a branch head.
    param([string]$Url, [string]$Rev)
    if ($Rev -match '^[0-9a-fA-F]{40}$') { return $Rev.ToLowerInvariant() }
    $escaped = [regex]::Escape($Rev)
    $lines = @(& git ls-remote $Url "refs/tags/$Rev" "refs/tags/$Rev^{}" "refs/heads/$Rev" 2>&1)
    if ($LASTEXITCODE) { throw "git ls-remote failed ($LASTEXITCODE): $Url $Rev`n$($lines -join "`n")" }
    $peeledTag = $lines | Where-Object { $_ -match ('refs/tags/' + $escaped + '\^\{\}$') } | Select-Object -First 1
    if ($peeledTag) { return ($peeledTag -split '\s+')[0].ToLowerInvariant() }
    $direct = $lines | Where-Object { $_ -match ('refs/(tags|heads)/' + $escaped + '$') } | Select-Object -First 1
    if ($direct) { return ($direct -split '\s+')[0].ToLowerInvariant() }
    throw "Cannot resolve '$Rev' in $Url (no such tag or branch)."
}

function Get-PinHash {
    # Stable fingerprint of a pin table, so Download-Sources.ps1 can tell
    # whether a non-git archive (ATL) is still in sync with its pinned hashes.
    param($Value)
    $json = $Value | ConvertTo-Json -Depth 8 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Lock file (sources.lock)
# ---------------------------------------------------------------------------

function Get-SourceLockPath {
    param([string]$Root)
    Join-Path $Root 'sources.lock'
}

function Read-SourceLock {
    param([string]$Root)
    $path = Get-SourceLockPath $Root
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $lock = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($lock.kind -ne 'obs-fdk-qsv-sources-lock-v1') { throw "Unrecognized sources.lock kind: $($lock.kind)" }
    return $lock
}

function Write-SourceLock {
    # Rewrites the lock only when the pins really changed, so re-running the
    # download command does not churn the committed file.
    param([string]$Root, $Lock)
    $path = Get-SourceLockPath $Root
    $newSources = $Lock.sources | ConvertTo-Json -Depth 6 -AsArray
    $newDownloads = $Lock.downloads | ConvertTo-Json -Depth 6 -AsArray
    if (Test-Path -LiteralPath $path) {
        $current = Read-SourceLock $Root
        if ($current -and
            ($current.sources | ConvertTo-Json -Depth 6 -AsArray) -eq $newSources -and
            ($current.downloads | ConvertTo-Json -Depth 6 -AsArray) -eq $newDownloads) {
            Write-Host '[SKIP] sources.lock is unchanged'
            return $false
        }
    }
    $Lock | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-Host "[LOCK] $path"
    return $true
}

function Test-SourceLock {
    # Build-side gate: the lock must exist and every archive it names must be
    # present with the recorded SHA256. Never touches the network.
    param([string]$Root, [string]$Cache)
    $lock = Read-SourceLock $Root
    if (!$lock) {
        throw "sources.lock not found in $Root. Run Download-Sources.ps1 on a networked machine to create the source cache and its lock."
    }
    $archives = @()
    foreach ($source in @($lock.sources)) { $archives += [pscustomobject]@{ Name = $source.archive; Sha256 = $source.sha256 } }
    foreach ($download in @($lock.downloads)) { $archives += [pscustomobject]@{ Name = $download.archive; Sha256 = $download.sha256 } }
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($archive in $archives) {
        $file = Join-Path $Cache $archive.Name
        if (!(Test-Path -LiteralPath $file)) { $problems.Add("$($archive.Name) is missing"); continue }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $archive.Sha256) {
            $problems.Add("$($archive.Name) does not match sources.lock (corrupt copy?)")
        }
    }
    if ($problems.Count) {
        throw "Source cache $Cache does not match sources.lock. Re-run Download-Sources.ps1 or copy the cache again:`n - " + ($problems -join "`n - ")
    }
    return $lock
}

function Get-LockedRepositories {
    param($Lock)
    foreach ($source in @($Lock.sources)) {
        [pscustomobject]@{
            Name = $source.name
            Url = $source.url
            Commit = $source.commit
            Submodules = [bool]$source.submodules
            CoreAbbrev = [int]$source.core_abbrev
        }
    }
}

function Get-LockedDownload {
    param($Lock, [string]$Name)
    if (!$Lock) { return $null }
    return @($Lock.downloads | Where-Object name -eq $Name)[0]
}

function Get-LockedSource {
    param($Lock, [string]$Name)
    if (!$Lock) { return $null }
    return @($Lock.sources | Where-Object name -eq $Name)[0]
}

# ---------------------------------------------------------------------------
# Pinned upstream inputs that follow the pinned source trees
# ---------------------------------------------------------------------------

function Get-PinnedAtl {
    [pscustomobject]@{
        Base = 'https://download.visualstudio.microsoft.com/download/pr/a62262cf-b9f6-4770-9454-7372ad8fcec0'
        # Key = VSIX part name, value = pinned SHA256 (also the URL path segment).
        Files = [ordered]@{
            Headers = 'df87bd5da5bb3d101ca8238cc4d5f90d648336202c41f2ab80b5549b7ac495d1'
            X64 = '6bf1c9950675fe9e5f46d861663ae19abcd18ce8e28602675194c32550ab3b04'
            X86 = '935a0f126b0c5a1f356103dabd2c8b6c74a1f6fa8292982ff7e8a4230d86fb50'
        }
    }
}

function Get-PinnedAtlFileName([string]$Part) { "Microsoft.VC.14.51.ATL.$Part.base.vsix" }

function Get-OfficialDependencySpecs([string]$ObsStudioPath) {
    # Mirrors the "dependencies" configure preset of obs-studio/CMakePresets.json:
    # which prebuilt archives OBS needs and where they unpack.
    $presets = Get-Content "$ObsStudioPath/CMakePresets.json" -Raw | ConvertFrom-Json
    $dependencies = ($presets.configurePresets | Where-Object name -eq dependencies).vendor.'obsproject.com/obs-studio'.dependencies
    $specs = @(
        @('prebuilt', 'x64', 'windows-deps-{0}-x64.zip', 'obs-deps-{0}-x64'),
        @('prebuilt', 'x86', 'windows-deps-{0}-x86.zip', 'obs-deps-{0}-x86'),
        @('qt6', 'x64', 'windows-deps-qt6-{0}-x64.zip', 'obs-deps-qt6-{0}-x64'),
        @('cef', 'x64', 'cef_binary_{0}_windows_x64.zip', 'cef_binary_{0}_windows_x64')
    )
    foreach ($spec in $specs) {
        $dep = $dependencies.($spec[0]); $arch = $spec[1]
        $fileName = $spec[2] -f $dep.version; $destination = $spec[3] -f $dep.version
        [pscustomobject]@{
            Kind = $spec[0]; Arch = $arch; Version = $dep.version
            FileName = $fileName; Destination = $destination
            Url = if ($spec[0] -eq 'cef') { "$($dep.baseUrl)/$fileName" } else { "$($dep.baseUrl)/$($dep.version)/$fileName" }
            Hash = $dep.hashes."windows-$arch"
        }
    }
}

# ---------------------------------------------------------------------------
# Cache archives
# ---------------------------------------------------------------------------

function Compress-SourceArchive {
    # Packs $Items (names relative to $WorkingDirectory) so each item name
    # becomes an archive root, replacing any previous archive of that name.
    param([string]$Archive, [string]$WorkingDirectory, [string[]]$Items)
    $sevenZip = Get-SevenZip
    $Archive = [IO.Path]::GetFullPath($Archive)
    if (Test-Path -LiteralPath $Archive) { Remove-Item -LiteralPath $Archive }
    Push-Location $WorkingDirectory
    try {
        & $sevenZip a -t7z -m0=zstd -mx=9 -bso0 -bsp0 $Archive @Items
        if ($LASTEXITCODE) { throw "7z a failed ($LASTEXITCODE): $Archive" }
    } finally { Pop-Location }
    Write-Host "[PACK] $Archive"
}

function Expand-SourceArchive {
    param([string]$Archive, [string]$Destination)
    $sevenZip = Get-SevenZip
    if (!(Test-Path -LiteralPath $Archive)) {
        throw "Source cache archive not found: $Archive. Run Download-Sources.ps1 on a networked machine and copy the source-cache directory here."
    }
    New-Item -ItemType Directory -Force $Destination | Out-Null
    & $sevenZip x -aoa -bso0 -bsp0 "-o$Destination" $Archive
    if ($LASTEXITCODE) { throw "7z x failed ($LASTEXITCODE): $Archive" }
}
