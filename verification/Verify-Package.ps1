$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$runtime = "$root/OBS-Studio-FDK-QSV/bin/64bit"
& "$PSScriptRoot/Compare-Codecs.ps1" -Runtime $runtime
Push-Location $runtime
try {
    $env:PATH = "$runtime;" + $env:PATH
    Copy-Item "$root/build/verification/Release/verify-obs.exe" "$runtime/verify-obs.exe" -Force
    & ./verify-obs.exe "$PSScriptRoot/standard-fdk.mkv" "$PSScriptRoot/custom-fdk.mkv" *> "$PSScriptRoot/obs-recording.log"
    if ($LASTEXITCODE) { throw "OBS recording verification failed: $LASTEXITCODE" }
    foreach ($name in @('standard-fdk','custom-fdk')) {
        $file = "$PSScriptRoot/$name.mkv"
        & ./ffprobe.exe -v error -show_streams -show_format -of json $file > "$PSScriptRoot/$name.json"
        if ($LASTEXITCODE) { throw "Could not probe $name" }
        $probe = Get-Content "$PSScriptRoot/$name.json" -Raw | ConvertFrom-Json
        $audio = $probe.streams | Where-Object codec_type -eq audio
        $video = $probe.streams | Where-Object codec_type -eq video
        if ($audio.codec_name -ne 'aac' -or $audio.sample_rate -ne '48000' -or $video.codec_name -ne 'h264' -or [double]$probe.format.duration -lt 2) {
            throw "Unexpected streams in $name"
        }
        & ./ffmpeg.exe -v error -xerror -i $file -f null - *> "$PSScriptRoot/$name-decode.log"
        if ($LASTEXITCODE) { throw "Decode failed for $name" }
        & ./ffmpeg.exe -hide_banner -i $file -vn -af volumedetect -f null - *> "$PSScriptRoot/$name-volume.log"
        if ($LASTEXITCODE) { throw "Audio check failed for $name" }
        $volume = Get-Content "$PSScriptRoot/$name-volume.log" -Raw
        if ($volume -notmatch 'mean_volume: (-?\d+(?:\.\d+)?) dB' -or [double]$Matches[1] -lt -40) { throw "Missing verification tone in $name" }
        Write-Host "PASS: $name, AAC stereo 48 kHz, H.264, duration $($probe.format.duration) s, audible test tone"
    }
    foreach ($encoder in @(
            'libfdk_aac', 'libx264', 'libsvtav1', 'libvpx', 'libvpx-vp9',
            'h264_nvenc', 'hevc_nvenc', 'av1_nvenc',
            'h264_amf', 'hevc_amf', 'av1_amf',
            'h264_qsv', 'hevc_qsv', 'av1_qsv')) {
        & ./ffmpeg.exe -hide_banner -h "encoder=$encoder" *> "$PSScriptRoot/$encoder-options.txt"
        if ($LASTEXITCODE) { throw "Encoder query failed: $encoder" }
        if (!(Select-String -LiteralPath "$PSScriptRoot/$encoder-options.txt" -SimpleMatch "Encoder $encoder" -Quiet)) {
            throw "Encoder missing from the custom FFmpeg build: $encoder"
        }
    }
} finally {
    Remove-Item -LiteralPath "$runtime/verify-obs.exe" -ErrorAction SilentlyContinue
    Pop-Location
}
