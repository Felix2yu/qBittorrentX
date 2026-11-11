# 本机只有 CommandLineTools：TestingMacros 插件在 plugins/testing/ 子目录里，
# swiftbuild 默认不扫子目录，必须显式 -load-plugin-library，否则 @Test/#expect 全部报
# "plugin for module 'TestingMacros' not found"。
SWIFT := swift
SANDBOX := -Xswiftc -disable-sandbox
TESTPLUGIN := -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib

.PHONY: build test perf release-test run clean check-model

build:
	$(SWIFT) build $(SANDBOX)

# AppModel 不 import SwiftUI，所以本机能单独 typecheck 它——@Observable 的插件在，
# 缺的只是 libSwiftUIMacros（@State/@Binding/@AppStorage）。并发边界因此有真实编译证据。
check-model: build
	swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 \
		-I .build/out/Products/Debug \
		-load-plugin-library /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libObservationMacros.dylib \
		App/Sources/QBittorrentXUI/AppModel.swift

test:
	$(SWIFT) test $(SANDBOX) $(TESTPLUGIN)

# 性能数字以 release 为准（debug 是 -Onone，慢 2~4 倍）。
perf:
	$(SWIFT) test -c release $(SANDBOX) $(TESTPLUGIN) --filter 性能测量

release-test:
	$(SWIFT) test -c release $(SANDBOX) $(TESTPLUGIN)

run:
	$(SWIFT) run $(SANDBOX) qbx

clean:
	$(SWIFT) package clean