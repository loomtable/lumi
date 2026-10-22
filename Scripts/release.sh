#!/bin/zsh
# Builds a release disk image of Lumi.app and its SHA-256 checksum. It uploads nothing.
#
#   git tag v0.1.0 && Scripts/release.sh     # dist/Lumi-0.1.0.dmg and .sha256, plus dist/Lumi.dmg and .sha256
#   Upload all four to the release; the website's Download button links releases/latest/download/Lumi.dmg.
#
# Releases are signed with the self-signed "Loomtable Release" identity and nothing else. macOS
# keys the Accessibility, Screen Recording and Input Monitoring grants to the signature's
# designated requirement; with one certificate every release has the same requirement, so users
# keep their grants across updates. Ad-hoc or dev-certificate releases would drop them. Gatekeeper
# treats it as an unidentified developer either way (System Settings › Privacy & Security › Open
# Anyway), until there's a Developer ID.
#
# Needs a clean tree with HEAD tagged v<CFBundleShortVersionString>. Never installs: the app is
# built with INSTALL=0 and removed from dist/ once it's in the image, so no second copy with the
# bundle ID stays registered with LaunchServices.
set -euo pipefail
cd "${0:a:h}/.."

cert="Loomtable Release"
fail() { echo "release: $*" >&2; exit 1 }

[[ -z $(git status --porcelain) ]] || fail "the working tree has changes; commit or stash them first."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' App/Info.plist)
tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
[[ $tag == "v$version" ]] || fail "HEAD must be tagged v$version (App/Info.plist); it's tagged '${tag:-nothing}'."

# The identity by its SHA-1, so another certificate with the same name can't be picked.
ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
sha=$(print -r -- "$ids" | awk -F'"' -v c="$cert" '$2 == c { split($1, a, " "); print a[2]; exit }')
[[ -n $sha ]] || fail "no valid \"$cert\" code-signing identity in the keychain. Releases are never signed ad-hoc or with the dev certificate."

INSTALL=0 SIGN_IDENTITY=$sha Scripts/build-app.sh
app=dist/Lumi.app

codesign --verify --strict --deep "$app"
# The requirement must name the release certificate, or users lose their grants on update.
req=$(codesign -d -r- "$app" 2>&1)
[[ ${req:l} == *"h\"${sha:l}\""* ]] || fail "the designated requirement doesn't name \"$cert\":"$'\n'"$req"
[[ -f $app/Contents/Resources/Assets.car ]] || fail "no app icon (Assets.car); release builds need Xcode's actool."
[[ -d $app/Contents/Resources/buddy-plugin/.claude-plugin ]] || fail "the buddy plugin is missing from the app."
for f in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
  [[ -f $app/Contents/Resources/$f ]] || fail "$f is missing from the app."
done

dmg="Lumi-$version.dmg"
stage=.build/dmg-stage
rm -rf "$stage" "dist/$dmg" "dist/$dmg.sha256"
mkdir -p "$stage"
ditto "$app" "$stage/Lumi.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname Lumi -srcfolder "$stage" -fs APFS -format UDZO "dist/$dmg"
# The image carries the same signature as the app, so a tampered download fails `codesign -v`.
codesign --force --timestamp=none --sign "$sha" "dist/$dmg"
codesign --verify --strict "dist/$dmg"
hdiutil verify -quiet "dist/$dmg"

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in "$stage/Lumi.app" "$app"; do "$lsregister" -u "${copy:A}" 2>/dev/null || true; done
rm -rf "$stage" "$app"

# Relative name, so `shasum -c Lumi-<version>.dmg.sha256` works in the download folder.
(cd dist && shasum -a 256 "$dmg" > "$dmg.sha256")
# A versionless copy, so the site can link releases/latest/download/Lumi.dmg straight to the file.
rm -f dist/Lumi.dmg dist/Lumi.dmg.sha256
cp "dist/$dmg" dist/Lumi.dmg
(cd dist && shasum -a 256 Lumi.dmg > Lumi.dmg.sha256)
echo "Built dist/$dmg (Lumi $version, build $build, signed: $cert ($sha))"
echo "SHA-256: $(cut -d' ' -f1 "dist/$dmg.sha256")"
