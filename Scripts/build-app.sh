#!/bin/zsh
# Builds Lumi.app from the SwiftPM product and installs it in /Applications.
#
#   Scripts/build-app.sh                 # build, sign, install /Applications/Lumi.app
#   INSTALL=0 Scripts/build-app.sh       # build dist/Lumi.app only (no install)
#   INSTALL_DIR=~/Applications Scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
#
# Signing, first found: SIGN_IDENTITY, "Loomtable Release", "Lumi Dev" (Scripts/make-dev-cert.sh),
# else ad-hoc. macOS keys permission grants to the bundle ID and the signature's designated
# requirement, not the path. A certificate identity's requirement names the certificate, so grants
# survive rebuilds and the move to /Applications. Ad-hoc signatures change on every build and lose
# them. Accessibility, Input Monitoring and Screen Recording grants are
# machine-wide and record the requirement they were granted to. So on a Mac with the release
# certificate, dev builds sign with it too: a dev build and a release then never invalidate each
# other's grants.
#
# Installing: a Lumi running from the install location is quit first (gracefully, then
# SIGTERM, then SIGKILL) and relaunched afterwards. The new build is copied next to the old one and
# swapped in with one atomic rename, never modified in place. Only the installed copy stays
# registered with LaunchServices, so `open -a Lumi`, login items and permissions all find that one.
set -euo pipefail
cd "${0:a:h}/.."

config=${CONFIG:-release}
install=${INSTALL:-1}
install_dir=${INSTALL_DIR:-/Applications}
bundle_id=com.loomtable.lumi
name="Lumi.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Identities by their SHA-1, so another certificate with the same name can't be picked.
identity=${SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
  for cert in "Loomtable Release" "Lumi Dev"; do
    identity=$(print -r -- "$ids" | awk -F'"' -v c="$cert" '$2 == c { split($1, a, " "); print a[2]; exit }')
    [[ -n $identity ]] && { signed_as="$cert ($identity)"; break }
  done
fi
identity=${identity:--}
[[ $identity == - ]] && signed_as="ad-hoc"
signed_as=${signed_as:-$identity}
echo "Signing with: $signed_as"

swift build -c "$config" --arch arm64
bin="$(swift build -c "$config" --arch arm64 --show-bin-path)"

# Built in a staging folder, so a running copy is never touched while building.
stage_dir=.build/app-stage
app="$stage_dir/$name"
rm -rf "$stage_dir"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Lumi" "$app/Contents/MacOS/Lumi"
# Debug and local symbols carry build-machine paths; the shipped binary doesn't need them.
strip -S -x "$app/Contents/MacOS/Lumi"
cp App/Info.plist "$app/Contents/Info.plist"
cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
# SwiftPM resource bundles (FluidAudio, KeyboardShortcuts). Their generated Bundle.module looks in
# Bundle.main.resourceURL, which is Contents/Resources in an app, and traps if the bundle is missing.
for bundle in "$bin"/*.bundle(N); do
  ditto "$bundle" "$app/Contents/Resources/${bundle:t}"
done
# The buddy plugin ships inside the app.
if [[ -d buddy-plugin/.claude-plugin ]]; then
  ditto buddy-plugin "$app/Contents/Resources/buddy-plugin"
fi
# The app icon is an Icon Composer file (light, dark, tinted and clear); App/Assets.xcassets holds the
# accent colour (ember, Info.plist NSAccentColorName), which the system uses for selected rows, focus
# rings and controls. actool compiles both to Assets.car and AppIcon.icns; it ships with Xcode, not the
# Command Line Tools. A broken icon stops the build; actool reports why on stdout, so its output is
# shown only when it fails.
if xcrun --find actool >/dev/null 2>&1; then
  if ! actool_out=$(xcrun actool App/AppIcon.icon App/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
      --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor --output-format human-readable-text \
      --output-partial-info-plist "$stage_dir/icon-info.plist" 2>&1); then
    print -r -- "$actool_out" >&2
    echo "actool couldn't compile App/AppIcon.icon or App/Assets.xcassets (see above)." >&2
    exit 1
  fi
  # actool exits 0 without output when --app-icon doesn't match the .icon's file name.
  [[ -f $app/Contents/Resources/Assets.car ]] || { echo "actool produced no Assets.car for App/AppIcon.icon." >&2; exit 1 }
else
  echo "actool not found (it comes with Xcode): building without the app icon." >&2
fi

# Notarisation requires a secure timestamp; ad-hoc and dev-certificate builds skip it.
# TIMESTAMP=1 forces it, e.g. for a Developer ID identity given by its hash.
ts=(--timestamp=none)
[[ $identity == "Developer ID"* || ${TIMESTAMP:-} == 1 ]] && ts=(--timestamp)

codesign --force --options runtime "${ts[@]}" \
  --entitlements App/Lumi.entitlements \
  --sign "$identity" "$app" || {
  echo "codesign failed. If the keychain is locked (e.g. over SSH), run: security unlock-keychain" >&2
  exit 1
}
codesign --verify --strict "$app"

# The staging copy must never be what LaunchServices opens.
unregister() { [[ -e $1 ]] || return 0; "$lsregister" -u "${1:A}" 2>/dev/null || true }

if [[ $install == 0 ]]; then
  rm -rf "dist/$name"
  mkdir -p dist
  ditto "$app" "dist/$name"
  unregister "$app"
  rm -rf "$stage_dir"
  echo "Built dist/$name (signed: $signed_as; not installed)"
  exit 0
fi

[[ $identity == - ]] && echo "Note: ad-hoc signed. Installing it resets permission grants; run Scripts/make-dev-cert.sh once to keep them." >&2

mkdir -p "$install_dir"
dest="${install_dir:A}/$name"   # canonical, so the pgrep anchor and the copy check match

# PIDs of processes running the executable at $1 (an install location's binary).
pids_of() { pgrep -f "^$1" || true }
installed_pids() { pids_of "$dest/Contents/MacOS/Lumi" }
wait_gone() {  # pids function, seconds
  local deadline=$(( SECONDS + $2 ))
  while [[ -n $($1) ]] && (( SECONDS < deadline )); do sleep 0.2; done
  [[ -z $($1) ]]
}
# Quits what `$1` lists: a normal quit by PID (another copy with the same bundle ID may be
# running) runs the app's own shutdown, which stops Claude Code and the key tap; then SIGTERM,
# then SIGKILL.
quit_all() {  # pids function, display name
  echo "Quitting the running $2…"
  for pid in $($1); do
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1 || true
  done
  if ! wait_gone $1 ${QUIT_TIMEOUT:-10}; then
    echo "It didn't quit in time; sending SIGTERM." >&2
    $1 | xargs kill -TERM 2>/dev/null || true
    wait_gone $1 3 || { $1 | xargs kill -KILL 2>/dev/null || true; wait_gone $1 2; } || {
      echo "$2 is still running; not replacing it." >&2
      exit 1
    }
  fi
}

was_running=0
# Whatever happens next, an app that was running is opened again on the way out.
trap '(( was_running )) && open "$dest"' EXIT
if [[ -n $(installed_pids) ]]; then
  was_running=1
  quit_all installed_pids Lumi
fi

# Copy beside the old app on the same volume, then swap the two in one atomic rename.
incoming="$install_dir/.Lumi.app.incoming"
rm -rf "$incoming"
ditto "$app" "$incoming"
if [[ -e $dest ]]; then
  python3 -I - "$incoming" "$dest" <<'PY'
import ctypes, ctypes.util, os, sys
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
RENAME_SWAP = 0x2
if libc.renamex_np(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), RENAME_SWAP) != 0:
    sys.exit(f"renamex_np swap failed: {os.strerror(ctypes.get_errno())}")
PY
  rm -rf "$incoming"   # now holds the previous build
else
  mv "$incoming" "$dest"
fi
codesign --verify --strict "$dest"

"$lsregister" -f "$dest"
unregister "$app"
rm -rf "$stage_dir"
# An old dist/ copy from before installs existed would be a second app with the same bundle ID.
for copy in "dist/$name"; do
  [[ -e $copy ]] || continue
  unregister "$copy"
  rm -rf "$copy"
done

# Advisory only: never fails the install.
others=$({ "$lsregister" -dump 2>/dev/null || true; } \
  | awk -v dest="$dest" '/^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); if ($0 ~ /\/Lumi\.app$/ && $0 != dest) print }' \
  | sort -u || true)
if [[ -n $others ]]; then
  echo "Other copies are registered with LaunchServices (from other checkouts). Remove them with:" >&2
  print -r -- "$others" | while IFS= read -r p; do print -r -- "  $lsregister -u \"$p\"" >&2; done
fi

# Relaunched through LaunchServices (`open`), so the app is its own responsible process for
# permissions. Started as a child of a terminal, macOS would attribute it to the terminal instead.
echo "Installed $dest (signed: $signed_as)"
(( was_running )) && echo "Relaunching Lumi."
true
