#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="/tmp/zebrunner/derivedDataPath/"
LOG_FILE="/tmp/zebrunner/build.log"
# Ignored by git (.gitignore: bundles/).
BUNDLES_DIR="$ROOT_DIR/bundles"
SIGNING_IDENTITY="Apple Development"
# Added for every action except analyze: Configurations/*.xcconfig runs the analyzer on each build.
FAST_BUILD_ARGS="RUN_CLANG_STATIC_ANALYZER=NO COMPILER_INDEX_STORE_ENABLE=NO"

# Used when Enter is pressed; arguments and environment variables take precedence.
DEFAULT_TARGET="runner"
DEFAULT_SDK="device"
DEFAULT_ACTION="build"
DEFAULT_DEST="generic"
DEFAULT_CODE_SIGN="no"
DEFAULT_TEAM_ID=""
DEFAULT_BUNDLE_ID=""
DEFAULT_PROVISIONING_UPDATES="no"
DEFAULT_IPHONE_MODEL=""
DEFAULT_IPAD_MODEL=""
DEFAULT_TV_MODEL=""
DEFAULT_IOS_VERSION=""
DEFAULT_TV_VERSION=""
DEFAULT_EXTRA_XC_ARGS=""

fail() {
  echo "Error: $*" >&2
  exit 1
}

usage() {
  cat <<EOF

Usage: bash Scripts/zebrunner-build.sh [--option value | --option=value]

  --target                lib | runner | tv_lib | tv_runner [default: $DEFAULT_TARGET]
  --sdk                   sim | device | tv_sim | tv_device [default: $DEFAULT_SDK]
  --action                build | analyze | unit_test | tv_unit_test | int_test_1 | int_test_2 | int_test_3 [default: $DEFAULT_ACTION]
  --dest                  none | iphone | ipad | tv | generic | tv_generic [default: $DEFAULT_DEST]
  --code-sign             yes | no [default: $DEFAULT_CODE_SIGN]
  --team-id               Apple Developer Team ID for device signing [default: ${DEFAULT_TEAM_ID:-not set}]
  --bundle-id             WebDriverAgentRunner bundle ID for device signing [default: ${DEFAULT_BUNDLE_ID:-project value}]
  --provisioning-updates  yes | no, let Xcode create/update profiles online [default: $DEFAULT_PROVISIONING_UPDATES]
  --iphone-model          iPhone simulator name [default: ${DEFAULT_IPHONE_MODEL:-not set}]
  --ipad-model            iPad simulator name [default: ${DEFAULT_IPAD_MODEL:-not set}]
  --tv-model              Apple TV simulator name [default: ${DEFAULT_TV_MODEL:-not set}]
  --ios-version           iOS simulator version [default: ${DEFAULT_IOS_VERSION:-not set}]
  --tv-version            tvOS simulator version [default: ${DEFAULT_TV_VERSION:-not set}]
  --extra-xc-args         Extra xcodebuild arguments without spaces in values [default: ${DEFAULT_EXTRA_XC_ARGS:-none}]
  --help                  Show this help

Missing values are requested interactively; Enter accepts the displayed default.

Edit DEFAULT_* at the top of this script to change defaults.

Arguments override environment variables; neither requires interactive confirmation.

SDK: sim/device = iOS simulator/device; tv_sim/tv_device = tvOS simulator/device.
DEST: generic = any physical iPhone/iPad; tv_generic = any physical Apple TV.
DEST: iphone/ipad/tv select simulators. For build, model and OS are optional:
leave both empty for Any Simulator. Tests and analysis require a model and OS version.
DEST: none leaves destination selection to Xcode. Mac builds are not supported.
Unit tests require lib/sim/iphone or ipad, or tv_lib/tv_sim/tv.
Integration tests require sim and iphone or ipad.
CODE_SIGN=no builds unsigned bundles; re-sign device builds before installing.
CODE_SIGN=yes on devices uses automatic "$SIGNING_IDENTITY" signing with TEAM_ID;
without provisioning updates, a matching local profile (e.g. TEAM_ID.*) is required.

Derived data is cleared before each run. Only runner builds are archived, into $BUNDLES_DIR
as WebDriverAgentRunner-Runner-<sdk>-<Xcode version>.zip.

Simulator archives include XCTest from this Xcode, so simctl install/launch works.
Except for analyze, $FAST_BUILD_ARGS is added before EXTRA_XC_ARGS.

Full build output is saved to $LOG_FILE.
EOF
}

while (($#)); do
  option="${1%%=*}"
  case "$option" in
    --help|-h) usage; exit 0 ;;
    --target|--sdk|--action|--dest|--code-sign|--team-id|--bundle-id|--provisioning-updates|\
    --iphone-model|--ipad-model|--tv-model|--ios-version|--tv-version|--extra-xc-args) ;;
    *) fail "Unknown option: $1" ;;
  esac
  if [[ "$1" == *=* ]]; then
    value="${1#*=}"
    shift
  else
    [[ $# -ge 2 && "$2" != --* ]] || fail "Missing value for $option"
    value="$2"
    shift 2
  fi
  name="$(printf '%s' "${option#--}" | tr '[:lower:]-' '[:upper:]_')"
  printf -v "$name" '%s' "$value"
done

prompt_value() {
  local name="$1" description="$2" default_name="DEFAULT_$1" value
  local default="${!default_name}"
  read -r -p "$name - $description [${default:-not set}]: " value \
    || fail "No input for $name. Pass --$(printf '%s' "$name" | tr '[:upper:]_' '[:lower:]-') or use interactive input."
  printf -v "$name" '%s' "${value:-$default}"
}

require_value() {
  local name="$1" description="$2" choice
  shift 2
  while [[ -z "${!name:-}" ]]; do
    prompt_value "$name" "$description${*:+ ($*)}"
    [[ -n "${!name:-}" ]] || echo "$name is required; no default is configured." >&2
  done
  [[ $# -gt 0 ]] || return 0
  for choice in "$@"; do
    [[ "${!name}" != "$choice" ]] || return 0
  done
  fail "Invalid $name '${!name}'; expected: $*"
}

simulator_value() {
  if [[ "$ACTION" == build ]]; then
    [[ "${!1+x}" ]] || prompt_value "$1" "$2 (optional for build; leave both model and OS empty for Any Simulator)"
  else
    require_value "$1" "$2"
  fi
}

require_value TARGET "iOS target, or tv_* for tvOS" lib runner tv_lib tv_runner
require_value SDK "sim=simulator, device=physical iOS; tv_* for tvOS" sim device tv_sim tv_device
require_value ACTION "Build, analyze, or run tests" build analyze unit_test tv_unit_test int_test_1 int_test_2 int_test_3
require_value DEST "generic/tv_generic=any device; iphone/ipad/tv=simulator (model/OS optional for build); none=Xcode chooses" none iphone ipad tv generic tv_generic
require_value CODE_SIGN "no=unsigned bundle; yes=sign (devices need a team ID)" yes no

case "$TARGET:$SDK" in
  lib:sim|lib:device|runner:sim|runner:device|\
  tv_lib:tv_sim|tv_lib:tv_device|tv_runner:tv_sim|tv_runner:tv_device) ;;
  *) fail "TARGET=$TARGET is incompatible with SDK=$SDK. Use lib/runner with sim/device, or tv_lib/tv_runner with tv_sim/tv_device." ;;
esac

case "$SDK:$DEST" in
  sim:none|sim:iphone|sim:ipad|sim:generic|device:none|device:generic|\
  tv_sim:none|tv_sim:tv|tv_sim:tv_generic|tv_device:none|tv_device:tv_generic) ;;
  *) fail "DEST=$DEST is incompatible with SDK=$SDK. iphone/ipad require sim; tv requires tv_sim. For devices use generic (iOS) or tv_generic (tvOS), or none." ;;
esac

case "$ACTION:$TARGET:$SDK:$DEST" in
  build:*|analyze:*|unit_test:lib:sim:iphone|unit_test:lib:sim:ipad|tv_unit_test:tv_lib:tv_sim:tv|\
  int_test_[123]:*:sim:iphone|int_test_[123]:*:sim:ipad) ;;
  *) fail "ACTION=$ACTION is incompatible with TARGET=$TARGET, SDK=$SDK, DEST=$DEST. Tests require a specific simulator, not an Any destination. Unit tests require lib/sim/iphone or ipad, or tv_lib/tv_sim/tv; integration tests require sim/iphone or ipad." ;;
esac

case "$DEST" in
  iphone) simulator_value IPHONE_MODEL "iPhone simulator name"; simulator_value IOS_VERSION "iOS simulator version" ;;
  ipad) simulator_value IPAD_MODEL "iPad simulator name"; simulator_value IOS_VERSION "iOS simulator version" ;;
  tv) simulator_value TV_MODEL "Apple TV simulator name"; simulator_value TV_VERSION "tvOS simulator version" ;;
  none) DEST="" ;;
esac

SIGN_ARGS=""
if [[ "$CODE_SIGN" == yes && ( "$SDK" == device || "$SDK" == tv_device ) ]]; then
  security find-identity -v -p codesigning | grep -qF "\"$SIGNING_IDENTITY" \
    || fail "No '$SIGNING_IDENTITY' certificate in the keychain. Add your account in Xcode > Settings > Accounts, or use --code-sign no."
  require_value TEAM_ID "10-character Apple Developer Team ID (Xcode > Settings > Accounts)"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Invalid TEAM_ID '$TEAM_ID'; expected 10 uppercase letters or digits."
  [[ "${BUNDLE_ID+x}" ]] || prompt_value BUNDLE_ID "Runner bundle ID; empty keeps the project value (.xctrunner is appended by Xcode)"
  [[ "${BUNDLE_ID:-}" =~ ^[A-Za-z0-9.-]*$ ]] || fail "Invalid BUNDLE_ID '$BUNDLE_ID'; use letters, digits, dots, and hyphens."
  require_value PROVISIONING_UPDATES "yes=Xcode may register IDs and create profiles on the Apple Developer portal" yes no
  # build.sh passes CODE_SIGN_IDENTITY="" and word-splits extra args, so the identity comes from the environment.
  SIGN_ARGS="CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$TEAM_ID CODE_SIGN_IDENTITY=\$(SIGNING_IDENTITY)"
  [[ -z "${BUNDLE_ID:-}" ]] || SIGN_ARGS="$SIGN_ARGS PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
  [[ "$PROVISIONING_UPDATES" != yes ]] || SIGN_ARGS="$SIGN_ARGS -allowProvisioningUpdates"
  export SIGNING_IDENTITY
fi

[[ "${EXTRA_XC_ARGS+x}" ]] || prompt_value EXTRA_XC_ARGS "Optional build settings; Enter keeps the default (empty means none)"
XC_ARGS="$SIGN_ARGS"
[[ "$ACTION" == analyze ]] || XC_ARGS="${XC_ARGS:+$XC_ARGS }$FAST_BUILD_ARGS"
# build.sh quotes this path literally, so reports would miss the ./clang directory it checks.
[[ "$ACTION" != analyze ]] || XC_ARGS="${XC_ARGS:+$XC_ARGS }CLANG_ANALYZER_OUTPUT_DIR=\$(SRCROOT)/clang"
EXTRA_XC_ARGS="$XC_ARGS${XC_ARGS:+${EXTRA_XC_ARGS:+ }}$EXTRA_XC_ARGS"

if [[ "$ACTION" == build ]]; then
  case "$DEST" in
    iphone) PLATFORM="iOS Simulator"; MODEL="${IPHONE_MODEL:-}"; OS="${IOS_VERSION:-}" ;;
    ipad) PLATFORM="iOS Simulator"; MODEL="${IPAD_MODEL:-}"; OS="${IOS_VERSION:-}" ;;
    tv) PLATFORM="tvOS Simulator"; MODEL="${TV_MODEL:-}"; OS="${TV_VERSION:-}" ;;
  esac
  if [[ "$DEST" == iphone || "$DEST" == ipad || "$DEST" == tv ]]; then
    MODEL="$(printf '%s' "$MODEL" | tr -d "'")"
    XC_DESTINATION="platform=$PLATFORM"
    if [[ -z "$MODEL" && -z "$OS" ]]; then
      XC_DESTINATION="generic/$XC_DESTINATION"
    else
      [[ -z "$MODEL" ]] || XC_DESTINATION="${XC_DESTINATION},name=$MODEL"
      [[ -z "$OS" ]] || XC_DESTINATION="${XC_DESTINATION},OS=$OS"
    fi
    # An empty DEST lets build.sh use the supplied XC_DESTINATION unchanged.
    DEST=""
    export XC_DESTINATION
  fi
fi

export TARGET SDK ACTION DEST CODE_SIGN DERIVED_DATA_PATH
export IPHONE_MODEL IPAD_MODEL TV_MODEL IOS_VERSION TV_VERSION EXTRA_XC_ARGS

BUILD_COMMAND=(env)
for name in TARGET SDK ACTION DEST CODE_SIGN DERIVED_DATA_PATH IPHONE_MODEL IPAD_MODEL TV_MODEL \
  IOS_VERSION TV_VERSION EXTRA_XC_ARGS XC_DESTINATION SIGNING_IDENTITY; do
  [[ -z "${!name+x}" ]] || [[ "$name" == SIGNING_IDENTITY && -z "$SIGN_ARGS" ]] \
    || BUILD_COMMAND+=("$name=${!name}")
done
BUILD_COMMAND+=(bash "$ROOT_DIR/Scripts/build.sh")

command -v xcodebuild >/dev/null || fail "xcodebuild not found; install Xcode."
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode / {print $2}')" \
  || fail "xcodebuild is not ready; run: sudo xcode-select -s /Applications/Xcode.app"
[[ -n "$XCODE_VERSION" ]] || fail "Cannot determine Xcode version"

ZIP_PATH=""
if [[ "$ACTION" == build && ( "$TARGET" == runner || "$TARGET" == tv_runner ) ]]; then
  ZIP_PATH="$BUNDLES_DIR/WebDriverAgentRunner-Runner-${SDK}-${XCODE_VERSION}.zip"
fi

printf '\nXcode %s, working directory: %s\n\nBuild command:\n' "$XCODE_VERSION" "$ROOT_DIR"
printf '%q ' "${BUILD_COMMAND[@]}"
printf '\n\nDerived data will be cleared: %s\n\nLog: %s\n\nArchive: %s\n\n\t' \
  "$DERIVED_DATA_PATH" "$LOG_FILE" "${ZIP_PATH:-none}"
read -r -p "Run build? [y/N]: " confirmation || fail "Confirmation is required; build not started."
case "$confirmation" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled; build not started."; exit 0 ;;
esac

cd "$ROOT_DIR"
mkdir -p "$DERIVED_DATA_PATH" "$(dirname "$LOG_FILE")"
find "$DERIVED_DATA_PATH" -mindepth 1 -delete
[[ "$ACTION" != analyze ]] || rm -rf "$ROOT_DIR/clang"
if ! "${BUILD_COMMAND[@]}" 2>&1 | tee "$LOG_FILE"; then
  echo >&2
  grep -E '(error|fatal):' "$LOG_FILE" | sort -u | tail -n 20 >&2 || true
  [[ -z "$SIGN_ARGS" ]] || echo "Signing hint: check TEAM_ID, try --provisioning-updates yes or --bundle-id, or use --code-sign no." >&2
  fail "$ACTION failed; full log: $LOG_FILE"
fi

if [[ "$ACTION" == analyze ]] && find "$ROOT_DIR/clang" -name '*.html' 2>/dev/null | grep -q .; then
  fail "Static analyzer found issues; see $ROOT_DIR/clang"
fi
[[ -n "$ZIP_PATH" ]] || { echo "$ACTION succeeded."; exit 0; }

# Simulator runtimes do not include XCTest, and xcodebuild only supplies it via DYLD_FRAMEWORK_PATH
# when it launches tests itself. Embed XCTest and its dependencies so `simctl launch` works.
embed_xctest() {
  local developer="$1" queue=("$BUNDLE/${BUNDLE%.app}") bin dep top dir src
  for bin in "$BUNDLE"/PlugIns/*.xctest; do queue+=("$bin/$(basename "$bin" .xctest)"); done
  mkdir -p "$BUNDLE/Frameworks"
  # Xcode's own test runner also embeds XCUnit, although nothing links it.
  [[ ! -d "$developer/Library/PrivateFrameworks/XCUnit.framework" ]] \
    || cp -R "$developer/Library/PrivateFrameworks/XCUnit.framework" "$BUNDLE/Frameworks/"
  while ((${#queue[@]})); do
    bin="${queue[0]}"
    queue=("${queue[@]:1}")
    for dep in $(otool -L "$bin" | awk '/^\t@rpath\// {print $1}'); do
      dep="${dep#@rpath/}"
      top="${dep%%/*}"
      [[ ! -e "$BUNDLE/Frameworks/$top" ]] || continue
      src=""
      for dir in Library/Frameworks Library/PrivateFrameworks usr/lib; do
        [[ ! -e "$developer/$dir/$top" ]] || { src="$developer/$dir/$top"; break; }
      done
      # Project frameworks such as WebDriverAgentLib are already embedded by Xcode.
      [[ -n "$src" ]] || continue
      cp -R "$src" "$BUNDLE/Frameworks/"
      queue+=("$BUNDLE/Frameworks/$dep")
    done
  done
  # Like Xcode, drop compile-time files from embedded frameworks.
  find "$BUNDLE/Frameworks" -depth \( -name Headers -o -name Modules \) -exec rm -rf {} +
}

case "$SDK" in
  sim) PLATFORM=iphonesimulator; SIM_PLATFORM=iPhoneSimulator ;;
  device) PLATFORM=iphoneos ;;
  tv_sim) PLATFORM=appletvsimulator; SIM_PLATFORM=AppleTVSimulator ;;
  tv_device) PLATFORM=appletvos ;;
esac
BUNDLE="WebDriverAgentRunner-Runner.app"
[[ "$TARGET" != tv_runner ]] || BUNDLE="WebDriverAgentRunner_tvOS-Runner.app"

cd "$DERIVED_DATA_PATH/Build/Products/Debug-$PLATFORM"
[[ -d "$BUNDLE" ]] || fail "App bundle not found: $PWD/$BUNDLE"
[[ -z "${SIM_PLATFORM:-}" ]] || embed_xctest "$(xcode-select -p)/Platforms/$SIM_PLATFORM.platform/Developer"
xattr -cr "$BUNDLE"
mkdir -p "$BUNDLES_DIR"
rm -f "$ZIP_PATH"
zip -qry "$ZIP_PATH" "$BUNDLE"
SUMMARY="$(du -h "$ZIP_PATH" | cut -f1)"
if [[ "$SDK" == device || "$SDK" == tv_device ]]; then
  [[ -f "$BUNDLE/embedded.mobileprovision" ]] && SUMMARY="$SUMMARY, signed" || SUMMARY="$SUMMARY, unsigned: re-sign before installing"
fi
echo "Zip bundled at $ZIP_PATH ($SUMMARY)"
