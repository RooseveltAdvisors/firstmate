#!/usr/bin/env bash
set -eu
version=v0.1.3
case "$(uname -m)" in
  x86_64) archive=scopey-linux-x64.tar.gz; checksum=bebb6f77aa4bcc7e4138ca53b3451b3332dcc679a3a073bdcd2612b1e5e926c2 ;;
  aarch64|arm64) archive=scopey-linux-arm64.tar.gz; checksum=3bbd644093b477ac1a1af6f462428c43fb60daaa2fe430736f32f00f4e0a5883 ;;
  *) echo "unsupported Scopey architecture: $(uname -m)" >&2; exit 1 ;;
esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSLo "$tmp/$archive" "https://github.com/ArchAstro/scopey/releases/download/$version/$archive"
printf '%s  %s\n' "$checksum" "$tmp/$archive" | sha256sum -c - >/dev/null
tar -xzf "$tmp/$archive" -C "$tmp"
install -m 0755 "$tmp/scopey" /usr/local/bin/scopey
