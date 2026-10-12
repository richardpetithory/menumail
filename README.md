# MenuMail

<img src="Assets/logo-120.png" width="80" alt="MenuMail logo">

A macOS menu bar app that shows your Gmail inboxes, one tab per account.

- **New-mail counts per account.** Each account counts the inbox messages that arrived since
  you last looked at its tab. Opening the popup clears the count for the tab it shows; the
  messages that were new stay marked until you close it.
- **Per-desktop selection.** Each desktop (Mission Control Space) remembers the tab you picked
  on it, e.g. Personal on Desktop 1 and Work on Desktop 2.
- **Browser profiles.** Each account can open its links (and its sign-in) in a specific
  Chromium browser profile (Brave, Chrome, Edge, Vivaldi, …), e.g. Brave's Work profile for
  the work account.
- **Read-only.** MenuMail asks only for `gmail.readonly`. Clicking a message opens it in Gmail.

## Build & run

```sh
make run       # build, install to /Applications/MenuMail.app, and launch
make test      # unit tests
make stop      # quit the running app
```

Requires macOS 14+ and Xcode / Swift 6.2+. Run `scripts/create-signing-cert.sh` once so builds
are signed with a stable "MenuMail Local Signing" identity and Keychain grants survive rebuilds.

Debug builds accept `--debug-window` (the popup with sample accounts in a regular window,
or `--debug-settings accounts|general|add` for the Settings window and add-account sheet), `--debug-window-empty` (welcome
screen), `--debug-menubar <dir>` (writes icon PNGs), and `--debug-logo <dir>` (regenerates
`Assets/logo-*.png` from the icon code: `.build/debug/menumail --debug-logo Assets`).

## Google setup

MenuMail signs in with standard OAuth in the browser: users pick their account on Google's page
and the browser redirects back to a temporary listener on 127.0.0.1. That needs a "Desktop app"
OAuth client from a Google Cloud project, created once by whoever builds MenuMail:

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project and
   [enable the Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
2. Under **Google Auth Platform**, set up branding (app name and emails; skip the logo, which
   triggers brand verification) with audience **External**, then **Publish** the app under
   Audience. In Testing mode Google expires sign-ins after 7 days.
3. Under **Clients**, create a client of type **Desktop app**.
4. Copy `Config/oauth-client.env.example` to `Config/oauth-client.env` (gitignored) and fill in
   the client ID and secret. `scripts/bundle.sh` embeds them in Info.plist, so `make run` and
   `make release` builds have a built-in client and users only click **Sign In with Google**.

Without that file, the app walks each user through creating their own client. Because
`gmail.readonly` is a restricted scope and the app isn't verified, users see a "Google hasn't
verified this app" warning (Advanced → Go to MenuMail), and the client is capped at 100 users.
A Google Workspace account whose admin blocks unverified apps can use **Use your own OAuth
client…** with a client from a project in that organization (audience **Internal**).

## How it works

```
Sources/menumail/
  App/       MenuBarExtra entry point (icon + count)
  Auth/      OAuth (browser + loopback + PKCE)
  Gmail/     Gmail API client: lists inbox/unread IDs, caches message metadata
  Model/     Account, MailMessage, MailStore (counts, popup lifecycle, polling, desktops)
  Support/   Keychain, HTTP, Desktops (private CGS Spaces API), Browsers (Chromium profiles)
  Views/     Popup screens and the code-drawn icons
```

- Inboxes refresh every minute, when the popup opens, and after waking from sleep. Each refresh
  is two list calls plus a metadata fetch for messages not seen before.
- Refresh tokens and client secrets are stored in the Keychain; everything else is in
  UserDefaults (`dev.menumail.menumail`).
- Desktop detection uses private CoreGraphics calls (`CGSGetActiveSpace`,
  `CGSCopyManagedDisplaySpaces`), looked up at runtime. If they go away, all desktops share one
  selection.

## Releases

MenuMail is distributed outside the App Store as a Developer ID–signed, notarized app, built
the same way as MaKeep:

```sh
make release-check            # next version + prerequisite check, changes nothing
make release                  # bump version, universal build, sign, notarize, staple → dist/MenuMail-x.y.z.zip
make release ARGS=--publish   # …and commit the bump, tag, push, and create a GitHub release
```

Releases need a Developer ID certificate, notarization credentials, and
`Config/oauth-client.env` (see the top of `scripts/release.sh`). The built-in OAuth client ends
up inside the shipped app, which is expected for desktop apps: Google doesn't treat their client
secrets as confidential. It's only kept out of git to avoid secret-scanner noise.

## Install

Download the latest `MenuMail-x.y.z.zip` from
[Releases](https://github.com/richardpetithory/menumail/releases), unzip it, and move
MenuMail.app to Applications. On first sign-in, Google warns that the app isn't verified; click
**Advanced → Go to MenuMail** to continue.
