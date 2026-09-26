# Roopam build and release pipeline.
#   make bump PART=patch   bump version (major|minor|patch|X.Y.Z), add CHANGELOG stub
#   make release           build, sign, package, tag and publish the DMG to GitHub
#   make icon SRC=x.png    rebuild app and helper icons from one artwork image
PLIST   := Roopam/Info.plist
VERSION  = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(PLIST))
BUILD    = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(PLIST))
DMG      = build/DMG/Roopam-$(VERSION).dmg
PART    ?= patch
PYTHON  ?= python3

.PHONY: help version bump build test dmg release icon clean

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
