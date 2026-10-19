# Overrides for the pinned obs-deps recipes: no tool installation, no 7-Zip dependency,
# no forced checkout of existing source trees, and verified downloads using PowerShell.
function Invoke-GitCheckout {
    param([string]$Uri, [string]$Commit, [string]$Path, [string]$Branch = 'master')
    if (!(Test-Path "$Path/.git")) {
        Invoke-External git init $Path
        Invoke-External git -C $Path remote add origin $Uri
    }
    $head = & git -C $Path rev-parse --verify HEAD 2>$null
    if ($head -ne $Commit) {
        if ($head) { throw "Existing source $Path is at $head, expected $Commit; refusing to overwrite it." }
        Invoke-External git -C $Path fetch --depth 1 origin $Commit
        Invoke-External git -C $Path checkout --detach $Commit
    }
}
function Invoke-SafeWebRequest {
    param([string]$Uri, [string]$HashFile, [switch]$Resume, [switch]$CheckExisting,
          [string]$OutFile = [IO.Path]::GetFileName($Uri))
    $expected = Import-Clixml $HashFile
    if (!(Test-Path $OutFile)) {
        # SourceForge serves its HTML download page to PowerShell's default UA.
        # Use its CLI download route, still requiring the pinned archive hash.
        Invoke-WebRequest -Uri $Uri -UserAgent 'curl/8.14.1' -OutFile "$OutFile.partial" -MaximumRetryCount 3
        $hash = Get-FileHash "$OutFile.partial" -Algorithm $expected.Algorithm
        if ($hash.Hash -ne $expected.Hash) { throw "Download hash mismatch: $Uri" }
        Move-Item -LiteralPath "$OutFile.partial" -Destination $OutFile
    }
    if ((Get-FileHash $OutFile -Algorithm $expected.Algorithm).Hash -ne $expected.Hash) { throw "Cached download hash mismatch: $OutFile" }
}
function Expand-ArchiveExt {
    param([string]$Path, [string]$DestinationPath = '.', [switch]$Force)
    if ($Path.EndsWith('.zip')) {
        Expand-Archive -LiteralPath $Path -DestinationPath $DestinationPath -Force:$Force
    } elseif ($Path.EndsWith('.gz')) {
        # The LAME recipe expects a .tar after this stage, then invokes tar itself.
        $inputStream = [IO.File]::OpenRead((Resolve-Path $Path))
        $gzipStream = [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
        $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path.Substring(0,$Path.Length - 3))
        $outputStream = [IO.File]::Create($outputPath)
        try { $gzipStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $gzipStream.Dispose(); $inputStream.Dispose() }
    } else { throw "Unsupported archive in pinned recipe: $Path" }
}
