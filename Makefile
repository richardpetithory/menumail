.PHONY: app run install stop test release release-check clean

BUILT = build.noindex/MenuMail.app
INSTALLED = /Applications/MenuMail.app

app:
	./scripts/bundle.sh release

# Installs to /Applications (the one copy Spotlight indexes) and launches it.
run: app stop
	rsync -a --delete $(BUILT)/ $(INSTALLED)/
	touch $(INSTALLED)  # Nudge Finder/Spotlight to pick up icon changes.
	open $(INSTALLED) || (sleep 1 && open $(INSTALLED))

install: run

# Matches bundled copies only, so debug preview runs (.build/debug/menumail) keep running.
stop:
	-pkill -f "MenuMail.app/Contents/MacOS/menumail"; while pgrep -f "MenuMail.app/Contents/MacOS/menumail" >/dev/null; do sleep 0.1; done

test:
	swift test

# Signed + notarized build in dist/ (see scripts/release.sh). ARGS=--publish for a GitHub release.
release:
	./scripts/release.sh $(ARGS)

release-check:
	./scripts/release.sh --dry-run

clean:
	rm -rf .build build.noindex dist
