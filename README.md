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
# バージョン宣言 (sources.psd1 / sources.lock)
cargo likeなバージョン指定を実装しています。version upに伴うABIの変更に注意してください。
| ファイル | 役割 |
| --- | --- |
| `sources.psd1` | `'fdk-aac' = 'v2.0.3'` のようにタグ・ブランチ・コミットを書く |
| `sources.lock` | 自動生成。コミットidとアーカイブのSHA256を記録 |

```PowerShell
# バージョン変更: sources.psd1 の該当行を書き換えるだけ
#   'fdk-aac' = 'v2.0.3'

# 変更された項目だけ解決・再取得し、sources.lock を更新
pwsh -executionpolicy bypass .\Download-Sources.ps1
# 特定の項目だけ更新 (cargo update -p 相当)
pwsh -executionpolicy bypass .\Download-Sources.ps1 -Package fdk-aac
```

# ダウンロードとビルドの分離
依存関係の取得(オンライン)とビルド(オフライン)は別コマンドに分離されています。

## ダウンロード(オンライン)
```PowerShell
pwsh -executionpolicy bypass .\Download-Sources.ps1
```
`source-cache\` に必要なソース・依存関係をすべて 7z(Zstandard圧縮)で格納します。`sources.lock` に各アーカイブのSHA256が記録され、ビルド前に検証されます。
| アーカイブ | 内容 |
| --- | --- |
| `git-<リポジトリ>.7z` | gitチェックアウト(.git履歴込み。OBS/FFmpegのバージョン文字列の再現に必要) |
| `codec-sources.7z` | obs-depsレシピ経由で取得したcodecソースツリー(opus/libogg/libvorbis/libvpx/svt-av1/aom/lame) |
| `atl.7z` | ATL開発用VSIX |
| `official-dependencies.7z` | OBS公式prebuilt依存(Windows deps / Qt6 / CEF) |

`sources.lock` と一致するアーカイブはスキップされるため、中断しても再実行で続きから取得できます。主なオプション:

| オプション | 動作 |
| --- | --- |
| `-Package <名前>` | 指定項目だけ再解決・再取得(cargo update -p 相当) |
| `-Update` | 全宣言を再解決(ブランチが進んだ場合など) |
| `-Locked` | lock が古ければエラーにし、取得もlock更新もしない |
| `-Force` | lock が最新でも全アーカイブを作り直す |
| `-SourceCache <path>` | 格納先の変更(既定: `.\source-cache`) |

アーカイブの合計サイズは約750MBです。

## ビルド(オフライン)
`source-cache\` と `sources.lock` をスクリプトと同じ場所(または `-SourceCache` で指定した場所)に置いて:
```PowerShell
pwsh -executionpolicy bypass .\Build-Reproduce.ps1
```
7z(Zstandard対応、例: 7-Zip ZS)が必要です。その他必要なツールは従来通りです。`sources.lock` のハッシュが変わると全ステージが再実行されます。
# OBS Binary Location
```

```
