#!/usr/bin/env bash
# uBlock Origin Lite の Safari 版（uBOLite.safari）をソースから作り、
# Kotone の 🧩 →「『ファイル』から取り込む…」で読める ZIP にする（rev.59）。
#
# 使い方:  scripts/build-ubol-safari.sh [出力先ディレクトリ]
# 必要なもの: git, node（22 以降）, jq, zip, ネットワーク（フィルターリストを取得する）
#
# uBOL-home リポジトリの chromium/ をそのまま取り込むと Chromium 向けのルール
# （Safari 向けの補正なし）と Chromium 向けの処理で動く。Safari 版は
# platform/mv3/safari/ の patch-ruleset.js / ext-compat.js で WebKit の差を吸収している。
set -euo pipefail

OUT_DIR="$(cd "${1:-.}" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[ubol] gorhill/uBlock を取得: $WORK/uBlock"
git clone -q --depth 1 https://github.com/gorhill/uBlock.git "$WORK/uBlock"
cd "$WORK/uBlock"
git submodule update --init --depth 1 \
  platform/mv3/extension/lib/codemirror/codemirror-ubol \
  platform/mv3/extension/lib/s14e-serializer
echo "[ubol] uBlock commit: $(git rev-parse HEAD)"

# 版は日付から作る（make-mv3.sh は x.y.z の形を求める）
# 各要素の先頭に 0 を付けない（10#… で 0905 → 905）
VERSION="$(TZ=UTC date +%Y).$((10#$(TZ=UTC date +%m%d))).$((10#$(TZ=UTC date +%H%M)))"
mkdir -p dist/build/mv3-data
tools/make-mv3.sh safari "$VERSION"

ZIP="dist/build/uBOLite_${VERSION}.safari.zip"
test -f "$ZIP"
# ZIP の直下に manifest.json があること（WKWebExtension が読める形）
unzip -l "$ZIP" | awk '{print $4}' | grep -qx manifest.json
cp "$ZIP" "$OUT_DIR/"
echo "[ubol] 出力: $OUT_DIR/$(basename "$ZIP")"
