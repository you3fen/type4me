#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
# Package only. Never quit, install over, launch or import data from another app.
export TYPE4ME_PERSONAL_BUILD=1
export APP_FLAVOR=public
export APP_NAME="Type4Me Personal"
export APP_BUNDLE_ID="com.you3fen.type4me.personal"
export URL_SCHEME="type4me-personal"
export APP_PATH="$ROOT/dist/$APP_NAME.app"
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
export VARIANT=cloud
export ARCH="${ARCH:-universal}"
export APP_BUILD="${APP_BUILD:-1}"
if [[ -f "$ROOT/Frameworks/sherpa-onnx.xcframework/Info.plist" || -f "$ROOT/Type4Me/CloudSubscription/marker" || -f "$ROOT/CppJiebaBridge/marker" ]]; then
  echo "Use a clean cloud-only checkout for the personal preview; refusing to alter local capability markers." >&2
  exit 1
fi
bash "$ROOT/scripts/package-app.sh"
/usr/libexec/PlistBuddy -c "Add :Type4MeSourceCommit string $(git -C "$ROOT" rev-parse HEAD)" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :Type4MeDataNamespace string Type4Me Personal" "$APP_PATH/Contents/Info.plist"
# Re-sign after embedding provenance; ad-hoc builds are not notarized.
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ROOT/dist/Type4Me-Personal-$ARCH.zip"
echo "Packaged (not installed): $ROOT/dist/Type4Me-Personal-$ARCH.zip"
