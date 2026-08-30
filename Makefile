CONFIG := release
BUILD := .build/$(CONFIG)
ARTIFACTS := artifacts

## リリースの workflow は版を make の引数で渡す。環境変数を見ないのは、VERSION が
## 他の用途で export されている環境で黙って乗っ取られないようにするため。
ifneq ($(origin VERSION), command line)
  ## 版タグ以外を拾うと、その文字列で sed の置換と配布物のパスが壊れる。
  VERSION := $(patsubst v%,%,$(shell git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null))
endif
ifeq ($(strip $(VERSION)),)
  VERSION := 0.0.0
endif

## dist は VARIANT=dev の文脈から release のバンドルを指すので、名前をここで持つ。
RELEASE_EXEC := Ediro

## 配布物は Developer ID で署名して公証する。手元には鍵がないので、識別名が
## 渡されなければ ad-hoc 署名に落とす。VERSION と同じ理由で環境変数は見ない。
ifneq ($(origin SIGN_IDENTITY), command line)
  SIGN_IDENTITY := -
endif
ifeq ($(SIGN_IDENTITY),-)
  CODESIGN_OPTIONS :=
else
  ## 公証は hardened runtime と署名時刻の両方を要求する。
  CODESIGN_OPTIONS := --options runtime --timestamp
endif

## 既定は開発用ビルド。日常的に使うビルドは `make release` で作る。
## 名前と bundle identifier が違うため、設定 (UserDefaults) と下書きの保存先も
## 別になる。開発中の操作が実際の下書きに触れない。
VARIANT ?= dev
ifeq ($(VARIANT),release)
  EXEC := $(RELEASE_EXEC)
  NAME := Ediro
  BUNDLE_ID := me.gin0606.ediro
else
  EXEC := EdiroDev
  NAME := Ediro Dev
  BUNDLE_ID := me.gin0606.ediro.dev
endif

BUNDLE := .build/$(EXEC).app
RELEASE_BUNDLE := .build/$(RELEASE_EXEC).app
DIST := .build/$(RELEASE_EXEC)-$(VERSION).zip
ICONSET := .build/$(EXEC).iconset
ICNS := .build/$(EXEC).icns

.PHONY: build test app run relaunch stop shot icon release dist dist-path check-notary notarize clean

build:
	swift build -c $(CONFIG)

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
	codesign --force $(CODESIGN_OPTIONS) --sign "$(SIGN_IDENTITY)" $(BUNDLE)
	@echo "built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

## 日常使いのビルドを手元で作る。/Applications へ入れるのは Homebrew 経由。
release:
	@$(MAKE) VARIANT=release app

dist: release
	@rm -f $(DIST)
	ditto -c -k --keepParent $(RELEASE_BUNDLE) $(DIST)
	@shasum -a 256 $(DIST)

## 前提はビルドより先に見る。zip まで作ってから鍵の不足で落ちると無駄が大きい。
## 空の secret を復号しても 0 バイトのファイルが残るので、鍵は中身の有無まで見る。
check-notary:
	@test -n "$(SIGN_IDENTITY)" && test "$(SIGN_IDENTITY)" != "-" || \
		{ echo "公証には Developer ID の署名が要ります (SIGN_IDENTITY)" >&2; exit 1; }
	@test -s "$$NOTARY_KEY" || \
		{ echo "NOTARY_KEY が指す鍵ファイルが空か存在しません" >&2; exit 1; }
	@test -n "$$NOTARY_KEY_ID" && test -n "$$NOTARY_ISSUER_ID" || \
		{ echo "NOTARY_KEY_ID / NOTARY_ISSUER_ID を環境変数で渡してください" >&2; exit 1; }

## staple 前の zip を配ると、Gatekeeper が初回起動時に Apple へ問い合わせに行く。
## 公開は取り消せないので、綴じた後に配布物を検分する。spctl はチケットが無くても
## オンラインの照会で通すため、綴じられたことは stapler validate の側で見る。
notarize: check-notary dist
	xcrun notarytool submit $(DIST) --key "$$NOTARY_KEY" --key-id "$$NOTARY_KEY_ID" \
		--issuer "$$NOTARY_ISSUER_ID" --wait --timeout 30m
	xcrun stapler staple $(RELEASE_BUNDLE)
	@rm -f $(DIST)
	ditto -c -k --keepParent $(RELEASE_BUNDLE) $(DIST)
	codesign --verify --strict --verbose=2 $(RELEASE_BUNDLE)
	xcrun stapler validate $(RELEASE_BUNDLE)
	spctl -a -vv -t exec $(RELEASE_BUNDLE)
	@echo "staple 済みの配布物:"
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
