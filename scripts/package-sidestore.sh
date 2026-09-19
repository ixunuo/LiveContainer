#!/bin/bash
set -euo pipefail

# Packages the LiveContainer+SideStore IPA (SideStore embedded as
# Frameworks/SideStoreApp.framework), mirroring the upstream .github/build_github.sh
# recipe with two deliberate deviations:
#   * ad-hoc signatures are produced with `codesign -f -s -` instead of `ldid -S`
#     (ldid asserts on SideStore's stripped-signature binaries)
#   * the Settings toggle is appended at the real specifier count instead of the
#     hardcoded index 3 the CI script uses, which writes malformed dictionaries
# The upstream script has no `set -e` and fails silently, so every step is
# verified here before the IPA is written.
#
# Usage: scripts/package-sidestore.sh <LiveContainer.xcarchive> [output.ipa]
# Env:   SIDESTORE_IPA=<SideStore.ipa>  DYLIBIFY=<dylibify binary>
#        LC_BUILD_CACHE=<cache dir>    (default: ~/.cache/lc-build)

LC_SRC=$(cd "$(dirname "$0")/.." && pwd)
ARCHIVE=${1:?usage: package-sidestore.sh <LiveContainer.xcarchive> [output.ipa]}
START=$PWD
OUT=${2:-LiveContainer+SideStore.ipa}
[[ "$OUT" = /* ]] || OUT="$START/$OUT"

CACHE=${LC_BUILD_CACHE:-$HOME/.cache/lc-build}
mkdir -p "$CACHE"
DYLIBIFY=${DYLIBIFY:-$CACHE/dylibify}
SIDESTORE_IPA=${SIDESTORE_IPA:-$CACHE/SideStore.ipa}
if [ ! -x "$DYLIBIFY" ]; then
    curl -fL --retry 3 -o "$DYLIBIFY" https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
    chmod +x "$DYLIBIFY"
fi
if [ ! -f "$SIDESTORE_IPA" ]; then
    curl -fL --retry 3 -o "$SIDESTORE_IPA" https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
cp -R "$ARCHIVE/Products/Applications" Payload
APP=Payload/LiveContainer.app
PB=/usr/libexec/PlistBuddy

# --- SideStore app group and URL schemes ---
$PB -c 'Add :ALTAppGroups array' "$APP/Info.plist"
$PB -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1 dict' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1:CFBundleURLSchemes array' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2 dict' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2:CFBundleURLSchemes array' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer' "$APP/Info.plist"
$PB -c 'Add :INIntentsSupported array' "$APP/Info.plist"
$PB -c 'Add :INIntentsSupported:0 string RefreshAllIntent' "$APP/Info.plist"
$PB -c 'Add :INIntentsSupported:1 string ViewAppIntent' "$APP/Info.plist"
$PB -c 'Add :NSUserActivityTypes array' "$APP/Info.plist"
$PB -c 'Add :NSUserActivityTypes:0 string RefreshAllIntent' "$APP/Info.plist"
$PB -c 'Add :NSUserActivityTypes:1 string ViewAppIntent' "$APP/Info.plist"

# --- Settings toggle, appended at the current specifier count ---
ROOT="$APP/Settings.bundle/Root.plist"
IDX=$($PB -c 'Print :PreferenceSpecifiers' "$ROOT" | grep -c 'Dict {')
$PB -c "Add :PreferenceSpecifiers:$IDX:Type string PSToggleSwitchSpecifier" "$ROOT"
$PB -c "Add :PreferenceSpecifiers:$IDX:Title string Open SideStore" "$ROOT"
$PB -c "Add :PreferenceSpecifiers:$IDX:Key string LCOpenSideStore" "$ROOT"
$PB -c "Add :PreferenceSpecifiers:$IDX:DefaultValue bool false" "$ROOT"

# --- embed SideStore as SideStoreApp.framework ---
unzip -q "$SIDESTORE_IPA" -d "$WORK/ss"
mv "$WORK/ss/Payload/SideStore.app" "$APP/Frameworks/SideStoreApp.framework"
"$DYLIBIFY" "$APP/Frameworks/SideStoreApp.framework/SideStore" "$APP/Frameworks/SideStoreApp.framework/SideStore.dylib"
rm "$APP/Frameworks/SideStoreApp.framework/SideStore"
mv "$APP/Frameworks/SideStoreApp.framework/SideStore.dylib" "$APP/Frameworks/SideStoreApp.framework/SideStore"
codesign -f -s - "$APP/Frameworks/SideStoreApp.framework/SideStore"
cp "$LC_SRC/.github/sidelc/LCAppInfo.plist" "$APP/Frameworks/SideStoreApp.framework/"

# --- SideStore intents metadata, renamed to the SideStoreSupport classes ---
cp "$APP/Frameworks/SideStoreApp.framework/Intents.intentdefinition" "$APP/"
cp "$APP/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition" "$APP/"
cp -r "$APP/Frameworks/SideStoreApp.framework/Metadata.appintents" "$APP/Metadata.appintents"
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' "$APP/Metadata.appintents/extract.actionsdata"
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' "$APP/Metadata.appintents/extract.actionsdata"

# --- widget extension ---
mv "$APP/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex" "$APP/PlugIns/LiveWidgetExtension.appex"
$PB -c 'Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget' "$APP/PlugIns/LiveWidgetExtension.appex/Info.plist"
$PB -c 'Set :CFBundleExecutable LiveWidgetExtension' "$APP/PlugIns/LiveWidgetExtension.appex/Info.plist"
mv "$APP/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension" "$APP/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension"
codesign -f -s - --entitlements "$LC_SRC/.github/sidelc/LiveWidgetExtension_adhoc.xml" "$APP/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension"

# the framework folder changed after its first ad-hoc signature; refresh the seal
codesign -f -s - "$APP/Frameworks/SideStoreApp.framework/SideStore"

# --- verify before packaging ---
codesign -v "$APP/Frameworks/SideStoreApp.framework/SideStore"
codesign -v "$APP/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension"
grep -aq '16SideStoreSupport20RefreshAllAppsIntentV' "$APP/Metadata.appintents/extract.actionsdata"
test -f "$APP/Frameworks/SideStoreApp.framework/LCAppInfo.plist"
$PB -c 'Print :ALTAppGroups:0' "$APP/Info.plist" | grep -qx 'group.com.SideStore.SideStore'
$PB -c "Print :PreferenceSpecifiers:$IDX:Key" "$ROOT" | grep -qx 'LCOpenSideStore'
echo "verification passed"

# --- package ---
zip -q -r "$OUT" Payload -x "._*" -x ".DS_Store" -x "__MACOSX"
echo "created: $OUT"
