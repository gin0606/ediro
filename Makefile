APP := Ediro
CONFIG := release
BUILD := .build/$(CONFIG)
BUNDLE := .build/$(APP).app
ICONSET := .build/$(APP).iconset
ICNS := .build/$(APP).icns
ARTIFACTS := artifacts

.PHONY: build test app run relaunch stop shot icon clean

build:
	swift build -c $(CONFIG)

test:
	swift test

## アイコンは図柄をコードで持ち、ここで各サイズへ展開する。
icon: $(ICNS)

$(ICNS): Tools/icon.swift
	@rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	swift Tools/icon.swift .build/icon-1024.png
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s .build/icon-1024.png --out $(ICONSET)/icon_$${s}x$${s}.png >/dev/null; \
		d=$$(($$s * 2)); \
		sips -z $$d $$d .build/icon-1024.png --out $(ICONSET)/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONSET) -o $(ICNS)

app: build $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
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
