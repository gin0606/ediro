CONFIG := release
BUILD := .build/$(CONFIG)
ARTIFACTS := artifacts

## 版番号の正本。
VERSION := 0.1.0

## dist は VARIANT=dev の文脈から release のバンドルを指すので、名前をここで持つ。
RELEASE_EXEC := Ediro

## 既定は開発用ビルド。日常的に使うビルドは `make release` で作る。
## 名前と bundle identifier が違うため、設定 (UserDefaults) と下書きの保存先も
## 別になる。開発中の操作が実際の下書きに触れない。
VARIANT ?= dev
ifeq ($(VARIANT),release)
  EXEC := $(RELEASE_EXEC)
  NAME := Ediro
  BUNDLE_ID := com.gin0606.ediro
else
  EXEC := EdiroDev
  NAME := Ediro Dev
  BUNDLE_ID := com.gin0606.ediro.dev
endif

BUNDLE := .build/$(EXEC).app
RELEASE_BUNDLE := .build/$(RELEASE_EXEC).app
DIST := .build/$(RELEASE_EXEC)-$(VERSION).zip
ICONSET := .build/$(EXEC).iconset
ICNS := .build/$(EXEC).icns

.PHONY: build test app run relaunch stop shot icon release dist version dist-path clean

build:
	swift build -c $(CONFIG)

## リリースの workflow がタグとの突き合わせに読む。
version:
	@echo $(VERSION)

## リリースの workflow が配布物の在処を読む。
dist-path:
	@echo $(DIST)

test:
	swift test

## アイコンは図柄をコードで持ち、ここで各サイズへ展開する。
## 開発用は色を変えて、Dock や撮影結果で取り違えないようにする。
icon: $(ICNS)

$(ICNS): Tools/icon.swift
	@rm -rf $(ICONSET) && mkdir -p $(ICONSET)
	swift Tools/icon.swift .build/icon-$(VARIANT).png $(VARIANT)
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s .build/icon-$(VARIANT).png --out $(ICONSET)/icon_$${s}x$${s}.png >/dev/null; \
		d=$$(($$s * 2)); \
		sips -z $$d $$d .build/icon-$(VARIANT).png --out $(ICONSET)/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONSET) -o $(ICNS)

app: build $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/Ediro $(BUNDLE)/Contents/MacOS/$(EXEC)
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(EXEC).icns
	sed -e 's/@NAME@/$(NAME)/g' -e 's/@EXEC@/$(EXEC)/g' -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' \
		-e 's/@VERSION@/$(VERSION)/g' \
		Support/Info.plist.in > $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

## 日常的に使うビルド。作ったら /Applications へ自分で移す。
release:
	@$(MAKE) VARIANT=release app

dist: release
	@rm -f $(DIST)
	ditto -c -k --keepParent $(RELEASE_BUNDLE) $(DIST)
	@shasum -a 256 $(DIST)

run: app
	open $(BUNDLE)

stop:
	@pkill -x $(EXEC) 2>/dev/null && echo "stopped $(EXEC)" || echo "$(EXEC) は起動していません"

relaunch: stop run

## 起動中のウィンドウを撮影する。前面に他アプリがあっても対象だけを撮る。
## 起動直後はウィンドウがまだ現れず描画も間に合わないため、見つかるまで待つ。
## 探すのは実行ファイル名 ($(EXEC)) ではなくバンドル名 ($(NAME))。ウィンドウの
## 所有者名は CFBundleName で、実行ファイル名とは別物。
shot:
	@mkdir -p $(ARTIFACTS)
	@id=""; for i in 1 2 3 4 5; do \
		id=$$(swift Tools/winid.swift '$(NAME)' 2>/dev/null) && break; \
		sleep 1; \
	done; \
	if [ -z "$$id" ]; then echo "$(NAME) のウィンドウが見つかりません" >&2; exit 1; fi; \
	screencapture -x -o -T 1 -l $$id -t png $(ARTIFACTS)/window.png && \
		echo "captured $(ARTIFACTS)/window.png"

clean:
	rm -rf .build $(ARTIFACTS)
