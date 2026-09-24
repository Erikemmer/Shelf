# Shelf – common tasks. `make help` lists them.
.DEFAULT_GOAL := help

# Where SwiftPM puts build products. The repo lives in a synced folder
# (`~/Documents`), and the sync attaches Finder metadata to freshly built files,
# which makes codesign refuse the test bundle ("resource fork, Finder
# information, or similar detritus not allowed"). Building outside the synced
# folder avoids it – the lesson from Selector. Override with `make test SCRATCH=.build`
# (CI calls `swift test` directly and is not affected).
SCRATCH ?= $(HOME)/Library/Caches/Shelf/build

# Where large test material goes. Never under ~/Documents: that folder is
# synced, and 5 000 generated books would be uploaded to iCloud.
CACHE ?= $(HOME)/Library/Caches/Shelf
SYNTHETIC ?= $(CACHE)/synthetic

.PHONY: help bootstrap test build lint format project app app-debug smoke synthetic synthetic-clean proof \
	online-proof online-library online-shots german-shots contrast accessibility runbook \
	organize-library organize-shots release release-dry clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

bootstrap: ## First-time setup on a Mac: check Xcode, install XcodeGen, run tests, generate + build + open the project
	@xcode-select -p >/dev/null 2>&1 || { echo "Xcode not found. Install it from the App Store, open it once, then re-run."; exit 1; }
	@command -v brew >/dev/null 2>&1 || { echo "Homebrew missing – install from https://brew.sh then re-run."; exit 1; }
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
	@# Files synced from other tools may carry Finder attributes that break codesign.
	xattr -cr . 2>/dev/null || true
	swift test --scratch-path $(SCRATCH)
	xcodegen generate
	xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Debug -quiet build SHELF_BUILD_COMMIT="$$(git rev-parse HEAD)"
	open Shelf.xcodeproj
	@echo "✅ Bootstrap done – press ⌘R in Xcode to run Shelf."

test: ## Run ShelfCore unit tests (works on macOS and Linux)
	swift test --scratch-path $(SCRATCH)

build: ## Build ShelfCore
	swift build --scratch-path $(SCRATCH)

lint: ## Check formatting with swift-format, and that no script can start Shelf without the guard
	swift format lint --recursive --strict Sources Tests App
	Scripts/check-shelf-guard.sh
	Scripts/check-current-app-guard.sh
	Scripts/check-screen-awake-guard.sh
	Scripts/check-array-guard.sh

format: ## Reformat sources in place
	swift format --in-place --recursive Sources Tests App

project: ## Generate Shelf.xcodeproj from project.yml (needs: brew install xcodegen)
	xcodegen generate

app: project ## Build the macOS app, Release (needs Xcode) – this is what gets started
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then \
		echo "app: Developer ID identity found — Hardened Runtime on"; \
		xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Release SHELF_HARDENED=YES build SHELF_BUILD_COMMIT="$$(git rev-parse HEAD)"; \
	else \
		echo "app: no Developer ID identity — ad-hoc build, Hardened Runtime off (see docs/adr/0022-updates-separate-delivery-sparkle.md)"; \
		xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Release SHELF_HARDENED=NO build SHELF_BUILD_COMMIT="$$(git rev-parse HEAD)"; \
	fi

app-debug: project ## Build the macOS app with assertions and symbols, for chasing a crash
	xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Debug build SHELF_BUILD_COMMIT="$$(git rev-parse HEAD)"

smoke: ## Launch the built app, open a library, check it shows a window and settles (SMOKE_LIBRARY=/path)
	@Scripts/smoke.sh

synthetic: build ## Generate a synthetic library of EPUBs for the proof run (COUNT=5000)
	swift run --scratch-path $(SCRATCH) shelf-tool synthesise "$(SYNTHETIC)" $(or $(COUNT),5000)

synthetic-clean: ## Delete the synthetic books and say how much space came back
	@Scripts/synthetic-clean.sh "$(SYNTHETIC)"

proof: ## Import the synthetic library twice (cold / warm) and print the timings
	@Scripts/proof-run.sh "$(SYNTHETIC)"

online-proof: ## Ask Open Library and Google Books about ten ISBNs and refresh the test fixtures (needs the network)
	@Scripts/online-proof.sh

online-library: ## Build the twelve-book library the Sprint 6 screenshots use
	@Scripts/online-library.sh

online-shots: online-library ## Photograph Fetch Metadata against the live services (needs an unlocked screen)
	@Scripts/online-shot.sh

german-shots: ## Photograph the window in German (needs an unlocked screen)
	@Scripts/german-shots.sh

contrast: ## Check every colour Shelf decides against WCAG AA (needs python3)
	@python3 Scripts/check-contrast.py

accessibility: ## Dump and judge the accessibility tree of every view (needs an unlocked screen)
	@Scripts/ax-proof.sh

organize-library: ## Build the 30-book library the Sprint 8 screenshots use
	@Scripts/organize-library.sh

organize-shots: organize-library ## Photograph the merge, organise and export sheets (needs an unlocked screen)
	@Scripts/organize-shot.sh

runbook: ## Run every path in docs/RUNBOOK.md once and print what it did
	@Scripts/runbook-proof.sh

release: ## Build, sign, notarise, staple and publish a downloadable Shelf to shelf-releases (needs a Developer ID)
	@Scripts/release.sh

release-dry: ## The same path with an ad-hoc signature, as far as notarisation – nothing published, needs nothing
	@RELEASE_DRY_RUN=1 Scripts/release.sh

clean: ## Remove build products
	rm -rf .build Shelf.xcodeproj DerivedData
