param([switch]$ConfigureOnly, [switch]$Resume)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot.Replace('\','/')
$stock = "$root/obs-studio/.deps/obs-deps-2026-08-26-x64"
$prefix = "$root/local"
foreach ($dir in @('ffnvcodec','AMF','srt','librist')) {
    Copy-Item "$stock/include/$dir" "$prefix/include" -Recurse -Force
}
Copy-Item "$stock/include/x264.h","$stock/include/x264_config.h","$stock/include/zlib.h","$stock/include/zconf.h" "$prefix/include" -Force
Copy-Item "$stock/lib/libx264.lib","$stock/lib/srt.lib","$stock/lib/librist.lib","$stock/lib/zlibstatic.lib" "$prefix/lib" -Force
Copy-Item "$stock/lib/zlibstatic.lib" "$prefix/lib/z.lib" -Force
function Write-Pc($name, $version, $libs, $flags = '') {
    @"
prefix=$($prefix.Replace('\','/'))
libdir=`${prefix}/lib
includedir=`${prefix}/include
Name: $name
Description: Official OBS dependency reused for custom FFmpeg
Version: $version
Libs: -L`${libdir} $libs
Cflags: -I`${includedir} $flags
"@ | Set-Content "$prefix/lib/pkgconfig/$name.pc" -Encoding utf8NoBOM
}
Write-Pc x264 0.164.3106 '-llibx264' '-DX264_API_IMPORTS'
Write-Pc srt 1.5.2 '-lsrt'
Write-Pc librist 0.2.7 '-llibrist'
Write-Pc ffnvcodec 13.0.19.0 ''
Write-Pc zlib 1.3.1 '-lzlibstatic'
Write-Pc vpl 2.17 '-lvpl -ladvapi32 -lole32' '-I${includedir}/vpl'
$msys = if ($env:OBS_REPRO_MSYS) { $env:OBS_REPRO_MSYS } else { 'C:/msys64' }
if (!$env:OBS_REPRO_MSYS) { $env:PATH = "$msys/mingw64/bin;$msys/usr/bin;" + $env:PATH }
$env:PKG_CONFIG_LIBDIR = "$prefix/lib/pkgconfig"
$env:MSYS2_PATH_TYPE = 'inherit'
$vsPath = if ($env:OBS_REPRO_VS) { $env:OBS_REPRO_VS } else { 'C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools' }
$vsId = if ($env:OBS_REPRO_VS_ID) { $env:OBS_REPRO_VS_ID } else { '53f15350' }
Import-Module "$vsPath/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstanceId $vsId -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$build = "$root/build/ffmpeg"
New-Item -ItemType Directory -Force $build | Out-Null
Set-Location $build

# ---------------------------------------------------------------------------
# FFmpeg configure options.
#
# Encoder pruning is only safe while these options survive: they provide the
# MSVC/Windows x64 target, the custom-ffmpeg install prefix, the OBS dependency
# include/lib paths, the shared-library layout OBS links against, libfdk-aac
# (--enable-nonfree), oneVPL for the QSV encoders (--enable-libvpl), and the
# external libraries whose encoders are whitelisted below.
# ---------------------------------------------------------------------------
$options = @(
    "--prefix=$root/custom-ffmpeg", '--arch=x86_64', '--toolchain=msvc', '--target-os=win64',
    "--extra-cflags=-D_WINDLL -MD -D_WIN32_WINNT=0x0A00 -I$prefix/include",
    "--extra-cxxflags=-MD -D_WIN32_WINNT=0x0A00 -I$prefix/include",
    "--extra-ldflags=-APPCONTAINER:NO -MACHINE:x64 -DEBUG -OPT:REF -OPT:ICF -LTCG -INCREMENTAL:NO -LIBPATH:$prefix/lib",
    '--pkg-config=pkgconf', '--pkg-config-flags=--static',
    '--enable-libaom', '--enable-libsvtav1', '--enable-libmp3lame',
    '--enable-w32threads', '--enable-version3', '--enable-gpl', '--enable-libx264', '--enable-libopus',
    '--enable-libvorbis', '--enable-libvpx', '--enable-librist', '--enable-libsrt', '--enable-shared', '--enable-zlib',
    '--disable-static', '--disable-libjack', '--disable-indev=jack', '--disable-sdl2', '--disable-doc', '--disable-debug',
    '--enable-nonfree', '--enable-libfdk-aac', '--enable-libvpl',
    '--disable-decoder=libfdk_aac,av1_qsv,h264_qsv,hevc_qsv,mjpeg_qsv,mpeg2_qsv,vc1_qsv,vp8_qsv,vp9_qsv,vvc_qsv',
    '--disable-filter=deinterlace_qsv,overlay_qsv,scale_qsv,vpp_qsv,hstack_qsv,vstack_qsv,xstack_qsv'
)
# Encoder whitelist: --disable-encoders drops every built-in encoder and the
# --enable-encoder list adds back only what OBS and the packaged ffmpeg.exe use.
# configure matches *component* names, not runtime names, so the external
# encoders appear as libvpx_vp8 / libvpx_vp9 / libaom_av1 (their runtime names
# are libvpx / libvpx-vp9 / libaom-av1). A name that matches nothing only prints
# a warning, hence the post-configure check below.
$videoEncoders = @(
    # H.264
    'libx264'
    'h264_nvenc', 'h264_amf', 'h264_qsv'
    # HEVC
    'hevc_nvenc', 'hevc_amf', 'hevc_qsv'
    # AV1
    'libsvtav1', 'libaom_av1'
    'av1_nvenc', 'av1_amf', 'av1_qsv'
    # VP8 / VP9
    'libvpx_vp8', 'libvpx_vp9'
    # Lossless / intermediate: OBS's "Lossless" quality records with utvideo.
    'ffv1', 'huffyuv', 'ffvhuff'
    'utvideo', 'prores_ks'
    # Not a real codec: the null muxer defaults to AV_CODEC_ID_WRAPPED_AVFRAME,
    # so "ffmpeg -f null -" (used by the verification scripts and by users as a
    # decode check) needs this passthrough encoder.
    'wrapped_avframe'
)
# Audio encoders OBS registers: ffmpeg_aac, ffmpeg_opus, pcm_*, alac, flac, plus
# libfdk_aac/libmp3lame/libvorbis for the bundled ffmpeg.exe.
$audioEncoders = @(
    'libfdk_aac', 'aac'
    'libopus', 'libvorbis', 'libmp3lame'
    'flac', 'alac'
    'pcm_s16le', 'pcm_s24le', 'pcm_f32le'
)
# Appended last so the whitelist overrides the global disables above. The
# former --disable-encoder=mjpeg_qsv,mpeg2_qsv,vp9_qsv line is redundant now:
# only whitelisted encoders are built.
$options += @(
    '--disable-encoders'
    "--enable-encoder=$(($videoEncoders + $audioEncoders) -join ',')"
)

if (!$Resume) {
    & "$msys/usr/bin/bash.exe" "$root/ffmpeg/configure" @options 2>&1 | Tee-Object -FilePath "$build/configure.log"
    if ($LASTEXITCODE) { throw 'FFmpeg configure failed' }
}
# An encoder name configure does not know is only a warning, and because the
# whitelist is passed as one comma-separated option, a single bad name stays
# silent. Dependency checks can drop an encoder as well (missing NVENC headers,
# oneVPL, AMF headers, ...). Verify the generated configuration instead of
# trusting the exit code.
foreach ($encoder in ($videoEncoders + $audioEncoders)) {
    $expected = "CONFIG_$($encoder.ToUpperInvariant())_ENCODER=yes"
    if (!(Select-String -LiteralPath "$build/ffbuild/config.mak" -SimpleMatch $expected -Quiet)) {
        throw "Encoder is missing from the configured build (unknown configure name or unmet dependency): $encoder"
    }
}
# Required when consuming OBS's shared x264 import library, including resumed builds.
$x264Rule = 'libavcodec/libx264.o: CFLAGS += -DX264_API_IMPORTS'
if (!(Select-String -LiteralPath ffbuild/config.mak -SimpleMatch $x264Rule -Quiet)) {
    Add-Content ffbuild/config.mak $x264Rule
    if (Test-Path libavcodec/libx264.o) { Remove-Item -LiteralPath libavcodec/libx264.o }
}
if (!$ConfigureOnly) {
    & "$msys/usr/bin/make.exe" -j8 all
    if ($LASTEXITCODE) { throw 'FFmpeg build failed' }
    & "$msys/usr/bin/make.exe" install
    if ($LASTEXITCODE) { throw 'FFmpeg install failed' }
}
