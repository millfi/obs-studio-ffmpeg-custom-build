$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$package = "$root/OBS-Studio-FDK-QSV"
$runtime = "$package/bin/64bit"
& robocopy "$root/obs-studio/build_x64/rundir/RelWithDebInfo" $package /E /XF '*.pdb' '*.lib' '*.exp' /NFL /NDL /NJH /NJS
if ($LASTEXITCODE -ge 8) { throw 'OBS runtime copy failed' }
Get-ChildItem "$root/custom-ffmpeg/bin/*.dll" | Copy-Item -Destination $runtime -Force
Copy-Item "$root/custom-ffmpeg/bin/ffmpeg.exe","$root/custom-ffmpeg/bin/ffprobe.exe" $runtime -Force
[IO.File]::WriteAllBytes("$package/portable_mode", [byte[]]@())
if (Test-Path "$package/portable_mode.txt") { Remove-Item -LiteralPath "$package/portable_mode.txt" }
Set-Content "$package/disable_updater.txt" 'Keep the custom FFmpeg build when running this portable copy.'
@'
@echo off
pushd "%~dp0bin\64bit"
start "" obs64.exe
popd
'@ | Set-Content "$package/Start-OBS.cmd" -Encoding ascii
Write-Host "Packaged: $package"
