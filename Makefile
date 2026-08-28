APP := Ediro
CONFIG := release
BUILD := .build/$(CONFIG)
BUNDLE := .build/$(APP).app
ARTIFACTS := artifacts

.PHONY: build test app run relaunch stop shot clean

build:
	swift build -c $(CONFIG)

test:
	swift test

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

run: app
	open $(BUNDLE)

stop:
	@pkill -x $(APP) 2>/dev/null && echo "stopped $(APP)" || echo "$(APP) は起動していません"

relaunch: stop run

## 起動中のウィンドウを撮影する。前面に他アプリがあっても対象だけを撮る。
## 起動直後はウィンドウがまだ現れず描画も間に合わないため、見つかるまで待つ。
shot:
	@mkdir -p $(ARTIFACTS)
	@id=""; for i in 1 2 3 4 5; do \
		id=$$(swift Tools/winid.swift $(APP) 2>/dev/null) && break; \
		sleep 1; \
	done; \
	if [ -z "$$id" ]; then echo "$(APP) のウィンドウが見つかりません" >&2; exit 1; fi; \
	screencapture -x -o -T 1 -l $$id -t png $(ARTIFACTS)/window.png && \
		echo "captured $(ARTIFACTS)/window.png"

clean:
	rm -rf .build $(ARTIFACTS)
