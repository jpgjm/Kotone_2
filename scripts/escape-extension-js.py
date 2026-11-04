#!/usr/bin/env python3
"""
escape-extension-js.py — Extension/*.js の ASCII 以外の文字を \\uXXXX に置き換える

rev.57 の実機で、background.js の日本語の文字列が文字化けして Swift に届いた
（「toggle が 15000ms で応答しません」→「toggle 縺� 15000ms 縺ｧ…」。UTF-8 を
Shift_JIS として読んだ形）。WebKit は拡張機能のファイルを
Content-Type: text/javascript（charset なし）で返す
（UIProcess/Extensions/Cocoa/WebExtensionURLSchemeHandlerCocoa.mm）。

ソースは読みやすいまま日本語で書き、CI でビルドの直前にだけこのスクリプトで
ASCII にする。\\uXXXX は文字列・テンプレート・正規表現・コメントのどこに
あっても同じ意味（コメントでは単なる文字）なので、構文は変わらない。
BMP 外の文字はサロゲートペアにする。

  python3 scripts/escape-extension-js.py Extension          # 置き換える
  python3 scripts/escape-extension-js.py --check Extension  # 残っていれば 1 で終わる
"""
import pathlib
import sys


def escape(text: str) -> str:
    out = []
    for ch in text:
        code = ord(ch)
        if code < 0x80:
            out.append(ch)
        elif code <= 0xFFFF:
            out.append("\\u%04x" % code)
        else:
            code -= 0x10000
            out.append("\\u%04x\\u%04x" % (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF)))
    return "".join(out)


def main() -> int:
    args = sys.argv[1:]
    check = "--check" in args
    dirs = [a for a in args if a != "--check"] or ["Extension"]
    bad = 0
    for d in dirs:
        for path in sorted(pathlib.Path(d).glob("*.js")):
            text = path.read_text(encoding="utf-8")
            count = sum(1 for ch in text if ord(ch) >= 0x80)
            if check:
                print(f"{'NG' if count else 'OK'} {path} (non-ASCII {count})")
                bad += 1 if count else 0
            else:
                path.write_text(escape(text), encoding="ascii")
                print(f"escaped {path} ({count} chars)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
