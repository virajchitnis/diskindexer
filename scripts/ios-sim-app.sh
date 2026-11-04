#!/bin/sh
# Builds the DiskIndexerIOS executable for the iOS Simulator and wraps it in
# build/DiskIndexerIOS.app. A stopgap until the app has its own Xcode target.
#   scripts/ios-sim-app.sh [derived-data-dir]
set -eu
cd "$(dirname "$0")/.."
DD=${1:-apple/.build/ios-sim}
APP=build/DiskIndexerIOS.app

(cd apple && xcodebuild -quiet -scheme DiskIndexerIOS \
	-destination 'generic/platform=iOS Simulator' \
	-derivedDataPath "${DD#apple/}" build)

rm -rf "$APP"
mkdir -p "$APP"
cp "$DD/Build/Products/Debug-iphonesimulator/DiskIndexerIOS" "$APP/"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.virajchitnis.diskindexer.ios</string>
	<key>CFBundleExecutable</key><string>DiskIndexerIOS</string>
	<key>CFBundleName</key><string>DiskIndexer</string>
	<key>CFBundleDisplayName</key><string>DiskIndexer</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
	<key>MinimumOSVersion</key><string>17.0</string>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UILaunchScreen</key><dict/>
	<key>UIApplicationSceneManifest</key>
	<dict><key>UIApplicationSupportsMultipleScenes</key><true/></dict>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>DiskIndexer connects to your server over SSH.</string>
</dict>
</plist>
EOF
codesign -s - --force "$APP" >/dev/null
echo "$APP"
