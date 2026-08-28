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
## 起動直後は描画が間に合わないことがあるため少し待ってから撮る。
shot:
	@mkdir -p $(ARTIFACTS)
	@id=$$(swift Tools/winid.swift $(APP)) && \
		screencapture -x -o -T 1 -l $$id -t png $(ARTIFACTS)/window.png && \
		echo "captured $(ARTIFACTS)/window.png"

clean:
	rm -rf .build $(ARTIFACTS)
