# Zen for iOS

Zen Browser's interface, rebuilt natively on WebKit.

![The vertical tab sidebar with spaces, essentials and pinned tabs](docs/screenshots/02-sidebar.png)

## Why this is not Gecko

Desktop Zen is a Firefox fork, so it renders with Gecko. Neither half of that
travels to iOS:

- **Apple requires WebKit.** Outside the EU, App Store guideline 2.5.6 still
  requires every browser to render with WKWebView. The alternative-engine
  entitlement introduced for the DMA is EU-only and needs a separate binary,
  a developer account in good standing and an Apple-approved engine — Gecko is
  not one.
- **Gecko has no iOS target.** There is no `--target=ios` in mozilla-central.
  Mozilla ship Firefox for iOS as a WKWebView shell for exactly this reason.

So this app does not try to port the engine. It ports the *browser* — the part
people actually choose Zen for. Spaces, vertical tabs, essentials, glance,
split view and compact mode are interface ideas, and interface ideas port fine.

Everything visual is derived from Zen's own source rather than eyeballed from
screenshots: the palette is a line-by-line port of `zen-theme.css`'s
`color-mix()` chain, the gradients follow `ZenGradientGenerator.mjs`, and the
metrics in `ZenMetrics.swift` are quoted from Zen's stylesheets with the
touch-sized deviations noted inline.

## Build and run

Requires **Xcode 27.0** (build 27A266a) and **xcodegen 2.46.0**
(`brew install xcodegen`). Deployment target iOS 17.0; iPhone and iPad.

```bash
cd ios
xcodegen generate
open Zen.xcodeproj          # or build from the command line:

xcodebuild build -scheme Zen -project Zen.xcodeproj \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/zenbuild CODE_SIGNING_ALLOWED=NO

xcodebuild test -scheme Zen -project Zen.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/zenbuild CODE_SIGNING_ALLOWED=NO
```

`Zen.xcodeproj` is committed alongside `project.yml` so the repo is clonable
without xcodegen, but `project.yml` is the source of truth — regenerate after
adding files.

There are **no third-party dependencies**: SwiftUI, WebKit and Foundation only.

### Screenshots

The images in this README are produced by a separate scheme that drives the app
through each state and writes PNGs into the UI-test runner's container:

```bash
xcodebuild test -scheme ZenScreenshots -project Zen.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/zenbuild CODE_SIGNING_ALLOWED=NO
cp "$(xcrun simctl get_app_container booted com.morton.zen.uitests.xctrunner data)/Documents/"*.png \
  docs/screenshots/
```

It is deliberately *not* part of `-scheme Zen`'s test action: it needs the
network and takes minutes, where the unit tests take under a second.

## Feature matrix

| # | Feature | State | Notes |
|---|---------|-------|-------|
| 1 | **Spaces** — named, icon, gradient theme | Done | Emoji or SF Symbol icon. Each space gets its own `WKWebsiteDataStore(forIdentifier:)`, so cookies and logins are isolated per space. |
| 1 | Space swipe to switch | Done | Horizontal drag on the sidebar translates the list live, then springs, as `ZenSpacesSwipe` does. |
| 1 | Space switcher strip | Done | Along the sidebar bottom, each chip previewing its own accent. |
| 2 | **Vertical tab sidebar** | Done | Slide-in drawer on iPhone (edge swipe or toolbar button), persistent on iPad. |
| 2 | Swipe to close a tab row | Done | Pull left past the threshold. |
| 2 | Reorder by drag | Partial | Essentials reorder by drag. Pinned and normal rows reorder through the model (`moveTab`) but have no drag gesture wired up yet. |
| 2 | Unloaded tabs | Done | An LRU pool keeps at most six live `WKWebView`s; the rest keep URL, title, favicon and scroll offset and reload on selection. Unloaded rows render dimmed and desaturated. |
| 3 | **Essentials** — global pinned grid | Done | Four across, favicon-only tiles, shared across every space, capped at 12 as upstream is. |
| 3 | Per-space pinned tabs | Done | Above the separator; closing one resets it to its pinned URL instead of destroying it. |
| 3 | Separator with clear affordance | Done | |
| 4 | **Omnibox** — floating bottom pill | Done | At the bottom on iPhone for thumb reach; upstream's is inline at the top. |
| 4 | Centered floating search box | Done | 62px, 12px radius, the large soft shadow, 252px result list. |
| 4 | Suggestions | Done | History (frecency-ranked), engine autocomplete, and a subset of Zen's urlbar global actions. |
| 4 | URL vs search detection | Done | Covered by tests, including `localhost`, IPv4, `.lan`, and refusing `javascript:`. |
| 4 | Search engine choice | Done | DuckDuckGo (default), Google, Bing, Startpage, Ecosia. Startpage has no public autocomplete endpoint and borrows DuckDuckGo's. |
| 4 | Desktop/mobile user agent | Done | Global setting; applied per web view at creation. |
| 5 | **Compact mode** | Done | Keeps Zen's two independent toggles (hide sidebar / hide toolbar), persisted. |
| 5 | Edge reveal | Partial | Tap the left or bottom edge strip to reveal, auto-hiding after 2.4s. Upstream reveals on *hover* within 10px; there is no hover on a touch screen, so this is a tap, and there is no equivalent of the outside-the-window mouse tracking. |
| 6 | **Split view** — two panes | Done | Side by side when wide (iPad, landscape iPhone), stacked when tall. Draggable divider with the same 7%-of-parent minimum. Focused pane gets the 2px accent outline. |
| 6 | 3–4 panes, grid/hsep layouts | **TODO** | Upstream's `MAX_TABS = 4` with a nested split tree. The model holds one secondary pane; extending it means replacing `splitSecondaryTabID` with a node tree. |
| 7 | **Glance** | Done | Long-press a link → "Open in Glance", or from a tab row's context menu. Card over a dimmed page with close / expand-to-tab / split-out. |
| 7 | Arc open/close animation | Partial | Upstream animates the card along an 80-step arc from the clicked element, with an `easeOutBack` overshoot and a snapshot of the source element. We use a spring scale-and-fade from centre. |
| 7 | Drag to dismiss | Done | An addition, not a port — upstream has a cursor and does not need one. |
| 8 | **Session restore** | Done | Spaces, tabs, tier, active tab per space, scroll offset and settings, as JSON in Application Support. Written through `replaceItemAt`, so a jetsam mid-write cannot truncate it. Snapshots are sanitised on load. |
| 9 | **History** with search | Done | JSON, capped at 5,000 entries, frecency-ish ranking. |
| 9 | **Bookmarks** | Done | Toggle in the omnibox pill; managed from the same sheet as history. |
| 10 | **Theme** — light/dark + Zen tokens | Done | Follows the system unless a themed space overrides it, which is what upstream's `shouldBeDarkMode()` does. |
| 10 | Per-space accent picker | Done | Swatches plus a harmony picker; the other dots derive from the same hue offsets the desktop wheel snaps to. |
| 10 | Full 380×380 colour wheel | Partial | The maths is ported (`ZenGradientGenerator.color(at:)` and its inverse) but the editor offers swatches rather than a draggable wheel. |
| 10 | Film grain | Partial | A generated noise tile at `.overlay` blend. Upstream ships `grain-bg.png` at `mix-blend-mode: hard-light`, which SwiftUI has no equivalent for. |
| 11 | **Keyboard shortcuts** | Done | ⌘T, ⌘W, ⌘L, ⌃Tab / ⌃⇧Tab, ⇧⌘S, ⇧⌘E, plus ⌘F and ⌃⇧← / ⌃⇧→. |
| 12 | **Share sheet** | Done | From the omnibox overflow menu. |
| 12 | **Find in page** | Partial | Uses WKWebView's `find(_:configuration:)`. `WKFindResult` reports only found/not-found, so there is no "3 of 12" counter. |
| 12 | **Reader mode** | **TODO** | WebKit exposes no reader/readability API to third-party apps. Implementing it means injecting a Readability port and rendering the result ourselves. |

### Also not done

- **Folders, live folders, mods, boosts, workspace routing.** Upstream features
  outside this brief.
- **Tab drag between spaces.**
- **Multi-window / Stage Manager** on iPad (`UIApplicationSupportsMultipleScenes`
  is `false`).
- **Downloads.** Links to non-renderable content are handed to the system.
- **Private browsing.** The per-space data store design makes this
  straightforward — an ephemeral `WKWebsiteDataStore` — but it is not wired up.
- **Favicons for never-visited tabs.** A restored tab shows a monogram disc
  until it is first loaded, because favicons are captured on navigation.

## Architecture

```
ios/
  project.yml              xcodegen spec — source of truth for the project
  Sources/
    App/                   ZenApp, RootView (layout, compact mode, shortcuts),
                           ContentArea, Info.plist
    Theme/                 ZenColor   — sRGB + CSS color-mix semantics
                           ZenPalette — the derived token set from zen-theme.css
                           ZenGradient / ZenGradientView — ZenGradientGenerator
                           ZenMetrics — constants quoted from Zen's stylesheets
    Model/                 Space, Tab, SearchEngine + URLDetector, BrowserState
    Persistence/           JSONFileStore (atomic), SessionStore, History/Bookmarks
    Web/                   WebEngine (per-space data stores, LRU pool), WebView
    UI/                    Sidebar/, Omnibox/, Glance/, Split/, History/,
                           Settings/, plus NewTabPage and FindBar
  Tests/ZenTests/          94 unit tests
  Tests/ZenUITests/        the screenshot driver
```

**`BrowserState` is the single source of truth.** Tabs live in one flat ordered
array; a "section" (essentials, this space's pinned tabs, its normal tabs) is a
filtered view of that array, so reordering is a splice and the session snapshot
stays a single list. This is the shape upstream converges on too — Zen keeps one
tab strip per space and filters by `zen-essential` and pinned state for display.

**The palette is computed, not chosen.** `zen-theme.css` declares exactly one
input — `--zen-primary-color`, the space accent — and `color-mix()`es it against
the branding base (`#101010` dark, `#e2e2e2` paper) to produce every other
token. `ZenPalette` ports that chain literally. `ZenColor.mix` implements CSS's
*premultiplied* alpha rule, without which every mix against `transparent` comes
out muddy instead of translucent.

**The web view pool, not SwiftUI, owns web view lifetime.** A `WKWebView` costs
a content process, so one per tab gets the app jetsammed with a few dozen tabs
open. `WebViewPool` keeps at most six and unloads the least-recently-used,
preserving everything needed to rebuild. `WebView.dismantleUIView` deliberately
does *not* tear anything down, because SwiftUI dismantles a representable
whenever its tab leaves the view tree — including when you merely open a sheet.

**Cookie isolation per space** replaces Zen's Firefox containers. Upstream notes
that two spaces sharing container 0 also share storage; giving every space its
own `WKWebsiteDataStore(forIdentifier:)` (iOS 17+) is strictly stronger.

### Deliberate divergences from upstream

| Upstream | Here | Why |
|---|---|---|
| — | Address bar selects all on focus | SwiftUI's `TextField` cannot select its contents, so the address bar is a small `UITextField` wrapper. Without it, tapping the bar and typing *appends* to the current URL. |
| urlbar inline at the top | Floating pill at the *bottom* on iPhone | A phone is held one-handed; the top of a modern iPhone is not thumb-reachable. |
| Close shortcut default `switch` | Pinned/essential close = `reset-unload-switch` | Swiping a row away has to visibly do something. Essentials still cannot be destroyed, only demoted. |
| Chrome revealed on hover | Revealed on an edge tap | No hover on a touch screen. |
| Invisible 5px splitter | 28pt hit area with a visible grab pill | A finger needs something to aim at. |
| Close button appears on row hover | Shown on the selected row; swipe otherwise | Same. |
| Glance: 80% wide, full height | 88% × 78%, centred | Full height on a phone is indistinguishable from just opening the tab. |
| `corner-shape: superellipse(1.3)` | `.continuous` rounded rectangles | SwiftUI has no superellipse corner shape. |
| Junicode serif wordmark | System serif | The font is not vendored. |

## Screenshots

| | |
|---|---|
| ![A loaded page with the space gradient framing it](docs/screenshots/01-page-example.png) | ![zen-browser.app loaded](docs/screenshots/03-page-zen.png) |
| A loaded page, the space gradient framing the content | A second page in the same space |
| ![The omnibox open with suggestions](docs/screenshots/05-omnibox.png) | ![A Glance card over the current page](docs/screenshots/04-glance.png) |
| The centered floating search box with suggestions | Glance: a link as a card over the dimmed page |
| ![Split view with two panes](docs/screenshots/06-split.png) | ![The persistent sidebar on iPad](docs/screenshots/02-sidebar-ipad.png) |
| Split view with a draggable divider | The persistent sidebar on iPad |

## Licence

Zen is MPL-2.0; this directory follows the repository's licence.
