#!/bin/zsh
# Publishes a new version to GitHub Releases. Team copies pick it up on their next launch.
# Usage: ./release.sh 1.2 "What changed in this version"
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?Usage: ./release.sh <version> \"release notes\"}"
NOTES="${2:-}"
PLIST=Resources/Info.plist

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or discard your changes first."; exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "v$VERSION already exists."; exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" $PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" $PLIST
./build.sh

git add $PLIST
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" build/Wulfe-Labeller.zip --title "Wülfe Labeller $VERSION" --notes "$NOTES"
echo "Released v$VERSION"
