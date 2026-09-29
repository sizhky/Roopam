# Roopam build and release pipeline.
#   make bump PART=patch   bump version (major|minor|patch|X.Y.Z), add CHANGELOG stub
#   make release           build, sign, package, tag and publish the DMG to GitHub
#   make varsha-run        rebuild Varsha, quit the running copy, open the new build
#   make icon SRC=x.png    rebuild app and helper icons from one artwork image
PLIST   := Roopam/Info.plist
VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(PLIST))
BUILD    = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(PLIST))
DMG      = build/DMG/Roopam-$(VERSION).dmg
PART    ?= patch
PYTHON  ?= python3

.PHONY: varsha varsha-test varsha-run help version bump build test dmg release icon clean

help:
	@sed -n 's/^#   //p' Makefile

version:
	@echo "$(VERSION) ($(BUILD))"

bump:
	@bash scripts/bump-version.sh $(PART)

build:
	bash scripts/build-local.sh

test: build
	bash scripts/check-local.sh

dmg: test
	bash scripts/build-release.sh

release:
	bash scripts/release.sh check
	$(MAKE) dmg
	bash scripts/release.sh

icon:
	@test -n "$(SRC)" || { echo "usage: make icon SRC=path/to/artwork.png"; exit 2; }
	$(PYTHON) scripts/make-app-icon.py $(SRC)

clean:
	rm -rf build build-local

varsha:
	bash scripts/build-varsha.sh

varsha-test:
	bash scripts/check-varsha.sh

varsha-run: varsha
	@pkill -x Varsha || test $$? -eq 1
	@for attempt in $$(seq 1 100); do \
		status=0; pgrep -x Varsha >/dev/null || status=$$?; \
		case $$status in 1) exit 0;; 0) sleep 0.05;; *) exit $$status;; esac; \
	done; \
	echo "Varsha did not exit within five seconds; launch cancelled." >&2; exit 1
	open -n build-varsha/Varsha.app
