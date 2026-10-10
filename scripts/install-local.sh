#!/bin/bash
# Run on the user's Mac, from any working directory.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'このスクリプトはmacOS専用です。' >&2; exit 1
fi
if [[ $# != 1 || -z "$1" || "$1" == '-' ]]; then
    echo '使用方法: bash scripts/install-local.sh "Apple Development: 名前 (識別子)"' >&2
    echo '署名証明書の確認: security find-identity -v -p codesigning' >&2
    exit 1
fi
capture_identity="$1"
capture_root="$(cd "$(dirname "$0")/.." && pwd)"
capture_target="$HOME/Applications/MacCaptureAutomation.app"
if pgrep -x MacCaptureAutomation >/dev/null; then
    echo '先にMacCaptureAutomationを終了してください（Xcodeの■、またはCommand+Q）。' >&2; exit 1
fi
xcodebuild -project "$capture_root/MacCaptureAutomation.xcodeproj" \
    -scheme MacCaptureAutomation -configuration Release \
    -derivedDataPath "$capture_root/build/signed" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$capture_identity" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build
capture_source="$capture_root/build/signed/Build/Products/Release/MacCaptureAutomation.app"
codesign --verify --strict "$capture_source"
capture_details="$(codesign -dv --verbose=4 "$capture_source" 2>&1)"
if ! [[ "$capture_details" == *"Authority="* ]] || [[ "$capture_details" == *"Signature=adhoc"* ]]; then
    echo '証明書による署名を確認できません。インストールを中止します。' >&2; exit 1
fi
capture_requirement="$(codesign -d -r- "$capture_source" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$capture_requirement" ]]; then
    echo '署名要件を確認できません。' >&2; exit 1
fi
if [[ -e "$capture_target" ]]; then
    if ! codesign --verify --strict "$capture_target"; then
        echo '既存アプリの署名を確認できません。既存アプリをFinderで別の場所へ保管してから再実行してください。' >&2; exit 1
    fi
    capture_previous="$(codesign -d -r- "$capture_target" 2>&1 | sed -n 's/^designated => //p')"
    if [[ "$capture_previous" != "$capture_requirement" ]]; then
        echo '前回と署名要件が異なります。権限登録を維持できない可能性があるため更新を中止しました。' >&2
        echo '同じ証明書を指定するか、初回移行として既存アプリをFinderで別の場所へ保管してください。' >&2; exit 1
    fi
fi
mkdir -p "$HOME/Applications"
capture_stage="$(mktemp -d "$HOME/Applications/.capture-install.XXXXXX")"
trap 'rm -rf "$capture_stage"' EXIT
ditto "$capture_source" "$capture_stage/MacCaptureAutomation.app"
codesign --verify --strict "$capture_stage/MacCaptureAutomation.app"
if [[ -e "$capture_target" ]]; then
    mv "$capture_target" "$capture_stage/previous.app"
fi
if ! mv "$capture_stage/MacCaptureAutomation.app" "$capture_target"; then
    if [[ -e "$capture_stage/previous.app" ]]; then mv "$capture_stage/previous.app" "$capture_target"; fi
    exit 1
fi
echo "インストール先: $capture_target"
echo '初回だけ、このアプリに画面収録・アクセシビリティを許可してください。'
echo '以後も同じ署名証明書・同じ場所を使用してください。'
open "$capture_target"
