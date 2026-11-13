# WebDriverAgent

[![NPM version](http://img.shields.io/npm/v/appium-webdriveragent.svg)](https://npmjs.org/package/appium-webdriveragent)
[![Downloads](http://img.shields.io/npm/dm/appium-webdriveragent.svg)](https://npmjs.org/package/appium-webdriveragent)

[![Release](https://github.com/appium/WebDriverAgent/actions/workflows/publish.js.yml/badge.svg)](https://github.com/appium/WebDriverAgent/actions/workflows/publish.js.yml)

[![GitHub license](https://img.shields.io/badge/license-BSD-lightgrey.svg)](LICENSE)

WebDriverAgent is a [WebDriver server](https://w3c.github.io/webdriver/webdriver-spec.html) implementation for iOS that can be used to remote control iOS devices. It allows you to launch & kill applications, tap & scroll views or confirm view presence on a screen. This makes it a perfect tool for application end-to-end testing or general purpose device automation. It works by linking `XCTest.framework` and calling Apple's API to execute commands directly on a device. WebDriverAgent is developed for end-to-end testing and is successfully adopted by [Appium](http://appium.io) via [XCUITest driver](https://github.com/appium/appium-xcuitest-driver).

## Features
 * Both iOS and tvOS platforms are supported with devices & simulators
 * Implements most of [WebDriver Spec](https://w3c.github.io/webdriver/webdriver-spec.html)
 * Implements part of [Mobile JSON Wire Protocol Spec](https://github.com/SeleniumHQ/mobile-spec/blob/master/spec-draft.md)
 * USB support for devices is implemented via [appium-ios-device](https://github.com/appium/appium-ios-device) library and has zero dependencies on third-party tools.
 * Easy development cycle as it can be launched & debugged directly via Xcode
 * Use [Mac2Driver](https://github.com/appium/appium-mac2-driver) to automate macOS apps

## Getting Started On This Repository

You need to have Node.js installed for this project.

After it is finished you can simply open `WebDriverAgent.xcodeproj` and start `WebDriverAgentRunner` test
and start sending [requests](https://github.com/facebook/WebDriverAgent/wiki/Queries).

More about how to start WebDriverAgent [here](https://github.com/facebook/WebDriverAgent/wiki/Starting-WebDriverAgent).

## Known Issues
If you are having some issues please checkout [wiki](https://github.com/facebook/WebDriverAgent/wiki/Common-Issues) first.

## For Contributors
If you want to help us out, you are more than welcome to. However please make sure you have followed the guidelines in [CONTRIBUTING](CONTRIBUTING.md).

## Creating Bundles

`npm run bundle`

Then, you find `WebDriverAgentRunner-Runner-sim-<version>.zip`  for iOS and `WebDriverAgentRunner-Runner-tv_sim-<version>.zip` for tvOS files in the current directory.

## Zebrunner build

`Scripts/zebrunner-build.sh` builds the WebDriverAgent of the Zebrunner MCloud device farm ([mcloud-agent](https://github.com/zebrunner/mcloud-agent), [mcloud-ios-connector](https://github.com/zebrunner/mcloud-ios-connector)). It runs `Scripts/build.sh` and needs only Xcode on macOS, not Node.js.

The minimum supported OS is iOS 15.0 and tvOS 15.0 (`IPHONEOS_DEPLOYMENT_TARGET` and `TVOS_DEPLOYMENT_TARGET` of `WebDriverAgent.xcodeproj`): older versions are not supported.

```bash
# Real iOS devices, signed (see Signing)
bash Scripts/zebrunner-build.sh --target runner --sdk device --dest generic \
  --code-sign yes --team-id ABCDE12345 --bundle-id= --provisioning-updates no --extra-xc-args= --yes
# iOS simulators (Any Simulator)
bash Scripts/zebrunner-build.sh --target runner --sdk sim --dest iphone \
  --iphone-model= --ios-version= --code-sign no --extra-xc-args= --yes
```

| Option | Values | Default |
| --- | --- | --- |
| `--target` | `lib`, `runner`, `tv_lib`, `tv_runner` | `runner` |
| `--sdk` | `sim`, `device`, `tv_sim`, `tv_device` | `device` |
| `--action` | `build`, `analyze`, `unit_test`, `tv_unit_test`, `int_test_1`, `int_test_2`, `int_test_3` | `build` |
| `--dest` | `generic`, `tv_generic` (any device), `iphone`, `ipad`, `tv` (simulator), `none` (Xcode chooses) | `generic` |
| `--code-sign` | `yes`, `no` | `no` |
| `--team-id` | Apple Developer Team ID, devices with `--code-sign yes` | none |
| `--bundle-id` | runner bundle ID, devices with `--code-sign yes`; empty keeps `com.facebook.WebDriverAgentRunner` | empty |
| `--provisioning-updates` | `yes` lets Xcode register IDs and create profiles on the Apple Developer portal, `no` | `no` |
| `--iphone-model`, `--ipad-model`, `--tv-model` | simulator name, optional for `build` | none |
| `--ios-version`, `--tv-version` | simulator OS version, optional for `build` | none |
| `--extra-xc-args` | extra `xcodebuild` arguments | none |
| `--package` | `ipa` (devices only), `zip` | `ipa` for devices, `zip` for simulators |
| `--yes`, `-y` | start without the confirmation prompt | prompt |

Options can also be set as environment variables (`TARGET=runner`, ...); arguments take precedence, missing values are requested interactively and the defaults are the `DEFAULT_*` values at the top of the script. Before the build the script prints the command and asks for confirmation, unless `--yes` is passed or stdin is not a terminal (CI). `bash Scripts/zebrunner-build.sh --help` describes the valid combinations.

`build` of `runner` and `tv_runner` writes to `bundles/` (ignored by git):

| SDK | File | Content | Use |
| --- | --- | --- | --- |
| `device`, `tv_device` | `WebDriverAgentRunner-Runner-<sdk>-<Xcode version>.ipa` | `Payload/WebDriverAgentRunner-Runner.app` (`WebDriverAgentRunner_tvOS-Runner.app` for tvOS) | `WDA_FILE` of a real device (default `/tmp/zebrunner/WebDriverAgent.ipa`), must be signed |
| `sim`, `tv_sim` | `WebDriverAgentRunner-Runner-<sdk>-<Xcode version>.zip` | the `.app` at the root, with XCTest of this Xcode embedded for `simctl launch` | `WDA_FILE` of a simulator |

`--package zip` of a device build keeps the `.app` at the root of a `.zip`, as before. Derived data is in `${TMPDIR:-/tmp}/zebrunner-wda-$USER/derivedDataPath` and is cleared before each run; the full output is saved to `build.log` next to it.

### Signing

The default `--code-sign no` produces an unsigned app: real devices install only a signed one. Either:

- build signed with `--code-sign yes --team-id <team>`: automatic signing with an `Apple Development` certificate of the keychain (Xcode > Settings > Accounts) and a provisioning profile of the team that matches the bundle ID (a wildcard one works), or `--provisioning-updates yes` to let Xcode create it;
- or re-sign the unsigned `.ipa` with your certificate and profile. The test bundle `PlugIns/WebDriverAgentRunner.xctest` and its frameworks need a signature too, which `fastlane resign` does not do:

  ```bash
  unzip -q WebDriverAgentRunner-Runner-device-<Xcode version>.ipa -d wda
  APP=wda/Payload/WebDriverAgentRunner-Runner.app
  IDENTITY="Apple Development: <name>"
  cp <profile>.mobileprovision "$APP/embedded.mobileprovision"
  security cms -D -i <profile>.mobileprovision > profile.plist
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' profile.plist > entitlements.plist
  # a wildcard profile has <team>.* here, the app needs its own ID
  /usr/libexec/PlistBuddy -c 'Set :application-identifier <team>.com.facebook.WebDriverAgentRunner.xctrunner' entitlements.plist
  find "$APP" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xctest' \) -exec codesign -f -s "$IDENTITY" {} \;
  codesign -f -s "$IDENTITY" --entitlements entitlements.plist "$APP"
  (cd wda && zip -qry ../WebDriverAgent.ipa Payload)
  ```

Xcode appends `.xctrunner` to the bundle ID of the runner: the default build is installed as `com.facebook.WebDriverAgentRunner.xctrunner`, the default `WDA_BUNDLEID` of mcloud-agent. With `--bundle-id com.example.wda` set `WDA_BUNDLEID=com.example.wda.xctrunner` in mcloud-agent (or `wda_bundleid` of the device).

## License

[`WebDriverAgent` is BSD-licensed](LICENSE).

## Third Party Sources

WebDriverAgent depends on the following third-party frameworks:
- [CocoaHTTPServer](https://github.com/robbiehanson/CocoaHTTPServer)
- [RoutingHTTPServer](https://github.com/mattstevens/RoutingHTTPServer)

These projects haven't been maintained in a while. That's why the source code of these
projects has been integrated directly in the WebDriverAgent source tree.

You can find the source files and their licenses in the `WebDriverAgentLib/Vendor` directory.

Have fun!
