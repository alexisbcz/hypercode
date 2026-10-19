export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

run: build
	-osascript -e 'tell application id "dev.alexis.Hypercode" to quit' 2>/dev/null
	while lsappinfo find bundleid=dev.alexis.Hypercode | grep -q ASN; do sleep 0.2; done
	open -n build/Build/Products/Debug/Hypercode.app

build:
	xcodegen generate -q
	xcodebuild -project Hypercode.xcodeproj -scheme Hypercode -derivedDataPath build -quiet build

.PHONY: run build
