param(
    [string]$Runtime = "$PSScriptRoot/../OBS-Studio-FDK-QSV/bin/64bit"
)
$ErrorActionPreference = 'Stop'
function Names($path) {
    @(Get-Content $path | ForEach-Object { if ($_ -match '^\s+[VAS][A-Z\.]{5}\s+([A-Za-z0-9][^\s]*)\s') { $Matches[1] } } | Sort-Object -Unique)
}

# Runtime names as printed by "ffmpeg -encoders". Keep in sync with the whitelist
# in ../Build-FFmpeg.ps1, which lists them under their configure component names
# (libvpx -> libvpx_vp8, libvpx-vp9 -> libvpx_vp9, libaom-av1 -> libaom_av1).
$requiredEncoders = @(
    'libx264'
    'h264_nvenc', 'h264_amf', 'h264_qsv'
    'hevc_nvenc', 'hevc_amf', 'hevc_qsv'
    'libsvtav1', 'libaom-av1'
    'av1_nvenc', 'av1_amf', 'av1_qsv'
    'libvpx', 'libvpx-vp9'
    'ffv1', 'huffyuv', 'ffvhuff'
    'utvideo', 'prores_ks'
    'wrapped_avframe'
    'libfdk_aac', 'aac'
    'libopus', 'libvorbis', 'libmp3lame'
    'flac', 'alac'
    'pcm_s16le', 'pcm_s24le', 'pcm_f32le'
)
# Deliberately pruned. This is what the whitelist buys us, so a regression that
# brings any of them back must fail loudly.
$forbiddenEncoders = @(
    'h261', 'h263', 'h263p', 'flv', 'jpeg2000', 'libtheora'
    'mpeg1video', 'mpeg2video', 'mpeg4', 'wmv1', 'wmv2', 'snow'
    'mjpeg_qsv', 'mpeg2_qsv', 'vp9_qsv', 'libx264rgb'
)
# Decoders are not pruned: OBS still has to open every media format it could
# open with the stock runtime.
$requiredDecoders = @(
    'h264', 'hevc', 'av1', 'vp8', 'vp9', 'mpeg2video', 'mpeg4'
    'aac', 'opus', 'vorbis', 'flac', 'alac'
    'pcm_s16le', 'pcm_s24le', 'pcm_f32le'
)
# ... except for these, which the configure line disables on purpose: one QSV
# decoder stack is enough, and the FDK decoder is not wanted next to the native
# AAC one.
$forbiddenDecoders = @(
    'av1_qsv', 'h264_qsv', 'hevc_qsv', 'mjpeg_qsv', 'mpeg2_qsv'
    'vc1_qsv', 'vp8_qsv', 'vp9_qsv', 'vvc_qsv', 'libfdk_aac'
)

$policy = @{
    encoders = @{ required = $requiredEncoders; forbidden = $forbiddenEncoders }
    decoders = @{ required = $requiredDecoders; forbidden = $forbiddenDecoders }
}
$failures = [Collections.Generic.List[string]]::new()
foreach ($kind in @('encoders', 'decoders')) {
    & "$Runtime/ffmpeg.exe" -hide_banner "-$kind" *> "$PSScriptRoot/custom-$kind.txt"
    if ($LASTEXITCODE) { throw "Could not enumerate $kind" }
    $stock = Names "$PSScriptRoot/stock-$kind.txt"
    $custom = Names "$PSScriptRoot/custom-$kind.txt"
    $required = @($policy[$kind].required)
    $forbidden = @($policy[$kind].forbidden)
    $missing = @($required | Where-Object { $_ -notin $custom })
    $unexpected = @($forbidden | Where-Object { $_ -in $custom })
    $extra = @($custom | Where-Object { $_ -notin $required })
    $removed = @($stock | Where-Object { $_ -notin $custom })
    $reasons = [Collections.Generic.List[string]]::new()
    if ($missing.Count) { $reasons.Add("missing=$($missing -join ',')") }
    if ($unexpected.Count) { $reasons.Add("unexpected=$($unexpected -join ',')") }
    # Encoder count is expected to drop; a decoder disappearing is a regression.
    if ($kind -eq 'decoders' -and $removed.Count) { $reasons.Add("removed=$($removed -join ',')") }
    # The encoder list is a whitelist: anything outside it is a policy violation.
    if ($kind -eq 'encoders' -and $extra.Count) { $reasons.Add("outside-whitelist=$($extra -join ',')") }
    $result = [ordered]@{
        kind = $kind
        stock_count = $stock.Count
        custom_count = $custom.Count
        added = @($custom | Where-Object { $_ -notin $stock })
        removed = $removed
        missing = $missing
        unexpected = $unexpected
        passed = ($reasons.Count -eq 0)
    }
    if ($kind -eq 'encoders') { $result.extra = $extra }
    $result | ConvertTo-Json | Set-Content "$PSScriptRoot/$kind-diff.json"
    $result | ConvertTo-Json
    if ($result.passed) {
        Write-Host "PASS: $kind, $($custom.Count) built, $($required.Count) required present, none forbidden"
    } else {
        Write-Host "FAIL: $kind, $($reasons -join '; ')"
        $failures.Add("$kind ($($reasons -join '; '))")
    }
}
if ($failures.Count) { throw "Codec policy validation failed: $($failures -join ' | ')" }
