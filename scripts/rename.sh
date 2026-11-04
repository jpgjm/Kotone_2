#!/bin/bash
# =============================================================================
# rename.sh — アプリ名と Bundle ID をまとめて変更する
#
#   ./scripts/rename.sh <NewName> <com.new.bundleid>
#
# 例:
#   ./scripts/rename.sh Kotone com.hayato.kotone
#
# rev.56 で Gecko を外したので、"Reynard Helper" の保護は不要になった。
# 拡張機能のネイティブアプリ名（background.js の NATIVE_APP = "kotone"）と
# context の ID（WebEngine.bridgeIdentifier = "kotone-bridge"）は小文字なので
# 置換されない（単語境界つき・大文字始まりのアプリ名だけを置換する）。
# =============================================================================
set -euo pipefail

if [ $# -ne 2 ]; then
	echo "usage: $0 <NewName> <com.new.bundleid>" >&2
	exit 1
fi

NEW_NAME="$1"
NEW_ID="$2"
OLD_NAME="$(grep -m1 '^name:' project.yml | awk '{print $2}')"
OLD_ID="$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER: ' project.yml | awk '{print $2}')"

if [ "$OLD_NAME" = "$NEW_NAME" ]; then
	echo "既に $NEW_NAME です"
	exit 0
fi

echo "  name:      $OLD_NAME -> $NEW_NAME"
echo "  bundle id: $OLD_ID -> $NEW_ID"

FILES=$(grep -rl "$OLD_NAME" \
	--include='*.yml' --include='*.sh' --include='*.md' \
	--include='*.swift' --include='*.plist' --include='*.json' . 2>/dev/null || true)

for f in $FILES; do
	# Bundle ID を先に置換（NEW_NAME に OLD_ID が含まれる事故を防ぐ）
	sed -i.bak "s|${OLD_ID}|${NEW_ID}|g" "$f"
	sed -i.bak "s|\\b${OLD_NAME}\\b|${NEW_NAME}|g" "$f"
	rm -f "$f.bak"
done

echo
echo "完了。xcodegen generate でプロジェクトを作り直してください。"
