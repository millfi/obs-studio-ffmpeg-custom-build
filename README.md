# OBSカスタムFFmpegビルド
OBSのカスタムFFmpeg出力で使えるcodecに手を加えたビルドスクリプトです。高音質なFDK-AAC codecとQSVを追加し、H.263やJPEG 2000などレガシーでOBSでは絶対使わないであろうcodecをすべて削除しています。カスタムFFmpeg出力で用いられるFFmpegのconfigure設定は以下の通りです。(`./Build-FFmpeg.ps1`から抜粋)
```PowerShell
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
$videoEncoders = @(
    'libx264', 'h264_nvenc', 'h264_amf', 'h264_qsv'
    'hevc_nvenc', 'hevc_amf', 'hevc_qsv', 'libsvtav1', 'libaom_av1', 'av1_nvenc', 'av1_amf', 'av1_qsv'
    'libvpx_vp8', 'libvpx_vp9'
    # Lossless / intermediate
    'ffv1', 'huffyuv', 'ffvhuff'
    'utvideo', 'prores_ks'
    # Not a real codec: the null muxer defaults to AV_CODEC_ID_WRAPPED_AVFRAME,
    # so "ffmpeg -f null -" (used by the verification scripts and by users as a
    # decode check) needs this passthrough encoder.
    'wrapped_avframe'
)
$audioEncoders = @(
    'libfdk_aac', 'aac'
    'libopus', 'libvorbis', 'libmp3lame'
    'flac', 'alac'
    'pcm_s16le', 'pcm_s24le', 'pcm_f32le'
)
# Appended last so the whitelist overrides the global disables above. The
$options += @(
    '--disable-encoders'
    "--enable-encoder=$(($videoEncoders + $audioEncoders) -join ',')"
)
```
# Build
```PowerShell
pwsh -executionpolicy bypass .\Build-Reproduce.ps1
```
# OBS Binary Location
```

```
