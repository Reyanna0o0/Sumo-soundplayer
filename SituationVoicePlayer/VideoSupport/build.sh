#!/bin/bash
# Rebuild the local AVI reader from the official FFmpeg n8.0.1 release tag.
# Pass a scratch directory for the bundled source archive and build objects.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
dest="$(cd "$(dirname "$0")" && pwd)"
scratch="${1:?Pass a scratch directory}"
mkdir -p "$scratch"
scratch="$(cd "$scratch" && pwd)"
repo_root="$(cd "$dest/../.." && pwd)"
archive="$repo_root/ThirdParty/FFmpeg/ffmpeg-n8.0.1.tar.gz"
echo "679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1  $archive" | shasum -a 256 -c -
src="$scratch/FFmpeg-n8.0.1"
if [[ ! -d "$src" ]]; then tar -xzf "$archive" -C "$scratch"; fi
build_slice() (
  sdk="$1"; arch="$2"; target="$3"; b="$scratch/avi-$sdk-$arch"
  mkdir -p "$b"; cd "$b"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  "$src/configure" --cc="$(xcrun --sdk "$sdk" -f clang)" --arch="$arch" --target-os=darwin \
    --sysroot="$sysroot" --enable-cross-compile --extra-cflags="-target $target -Os -ffile-prefix-map=\"$scratch\"=." \
    --extra-ldflags="-target $target" --disable-everything --disable-autodetect --disable-programs \
    --disable-doc --disable-debug --disable-network --disable-asm --disable-avdevice --disable-avfilter \
    --disable-swresample --disable-swscale --enable-small --enable-protocol=file --enable-demuxer=avi \
    --enable-muxer=mov --enable-parser=h264,hevc,mpeg4video,mpegaudio,mjpeg,aac \
    --enable-decoder=h264,mpeg4,mjpeg,aac,mp3 --enable-bsf=extract_extradata,aac_adtstoasc
  make -j4 libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a
  xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sysroot" -Os -ffile-prefix-map="$repo_root"=. -c "$dest/SimoAVI.c" \
    -I"$b" -I"$src" -o SimoAVI.o
  xcrun libtool -static -o libsimoavi.a SimoAVI.o libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a
)
mkdir -p "$dest/lib/iphoneos" "$dest/lib/iphonesimulator"
build_slice iphoneos arm64 arm64-apple-ios18.0
cp "$scratch/avi-iphoneos-arm64/libsimoavi.a" "$dest/lib/iphoneos/"
build_slice iphonesimulator arm64 arm64-apple-ios18.0-simulator
build_slice iphonesimulator x86_64 x86_64-apple-ios18.0-simulator
xcrun lipo -create "$scratch/avi-iphonesimulator-arm64/libsimoavi.a" "$scratch/avi-iphonesimulator-x86_64/libsimoavi.a" -output "$dest/lib/iphonesimulator/libsimoavi.a"
