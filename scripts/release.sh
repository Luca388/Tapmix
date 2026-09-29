#!/usr/bin/env bash
# DMG 를 만들어 Sparkle 로 서명하고, appcast.xml 과 함께 GitHub Release 로 올린다.
#
#   scripts/release.sh release-notes.html
#
# 먼저 Xcode 에서 MARKETING_VERSION(표시 버전)과 CURRENT_PROJECT_VERSION(빌드 번호)을 올린다.
# Sparkle 은 빌드 번호로 새 버전을 판단하므로 빌드 번호는 매번 커져야 한다.
# 서명 개인 키는 이 Mac 의 로그인 키체인에 있다 (Sparkle generate_keys 로 생성, -x 로 백업 가능).
#
# 앱은 SUFeedURL = releases/latest/download/appcast.xml 을 읽으므로
# 새 릴리스가 "Latest" 가 되는 순간 기존 사용자에게 업데이트가 뜬다.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="Luca388/Tapmix"
NOTES="${1:?사용법: scripts/release.sh <release-notes.html>}"

# 릴리스 태그가 가리킬 커밋은 원격에 있어야 한다
if [[ -n "$(git status --porcelain)" ]]; then
  echo "커밋 안 한 변경이 있다." >&2
  exit 1
fi
git fetch -q origin
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "HEAD 가 origin/main 에 push 되지 않았다." >&2
  exit 1
fi

scripts/make-dmg.sh

APP="build/release/Tapmix.app"
DMG="dist/Tapmix.dmg"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
TAG="v$VERSION"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "이미 $TAG 릴리스가 있다. 버전을 올려라." >&2
  exit 1
fi

SPARKLE_BIN=$(ls -d build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin)
echo "==> Sparkle 서명"
# 출력: sparkle:edSignature="..." length="..."
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$DMG")

echo "==> appcast.xml"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tapmix</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[$(cat "$NOTES")]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Tapmix.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

echo "==> GitHub Release $TAG"
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT
{
  cat "$NOTES"
  echo
  echo "<hr>"
  echo
  echo "**설치:** [Tapmix.dmg](https://github.com/$REPO/releases/latest/download/Tapmix.dmg) 를 열고 Applications 로 끌어다 놓는다."
  echo "처음 실행 시 Gatekeeper 가 막으면 Finder 에서 우클릭 › 열기. 이후 업데이트는 앱이 알아서 받는다."
  echo
  echo "SHA-256: \`$(shasum -a 256 "$DMG" | cut -d' ' -f1)\`"
} > "$BODY"

gh release create "$TAG" "$DMG" dist/appcast.xml \
  --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Tapmix $VERSION" --notes-file "$BODY" --latest
echo "==> 완료: https://github.com/$REPO/releases/tag/$TAG"
