# Skeuo4Ever

**What if iOS 7 had never gone flat?**

Skeuo4Ever brings the features of later iOS versions to iOS 6 and builds them from the same materials Apple
used back then: glass, linen, leather, paper, metal, glossy buttons and embossed text. New things are woven
into the native iOS 6 interface instead of being painted over it — so they look as if they had always been
there. Skeuomorphism forever.

Everything is written from scratch. The target is an iPhone 4S on iOS 6.1.3 (armv7), but the packages install
on any device with iOS 6.0–6.1.x.

[Русская версия](README.ru.md)

## Features

| Package | From | How it looks on iOS 6 |
|---|---|---|
| `com.skeuo4ever.controlcenter` — Control Center | iOS 7 | Swipe up from the bottom edge (an Activator gesture): grey linen and square buttons in grey frames, like Auxo, native brightness and volume sliders, music, flashlight; the iOS 7 iPad layout in landscape |
| `com.skeuo4ever.screenshot` — Screenshot Preview | iOS 11 | The screenshot shrinks into the corner as a photo in a white frame; tap it for markup with the black bars of Photos, pen, marker and eraser; the cross deletes it |
| `com.skeuo4ever.keyboardcursor` — Space Bar Cursor | iOS 12 | Slide along the space bar to move the cursor by letters and lines; slide from Shift to select |
| `com.skeuo4ever.swipeback` — Swipe Back | iOS 7 | A swipe from the left edge; both screens slide together, as in the iOS 6 animation, with a shadow along the edge |
| `com.skeuo4ever.battery` — Low Power Mode | iOS 9 | The battery fill turns yellow; the "20 % of battery remaining" alert gets a Low Power Mode button |
| ↳ Battery Health | iOS 11.3 | A screen with maximum capacity, cycle count and temperature, built from native Settings cells |
| `com.skeuo4ever.nightshift` — Night Shift | iOS 9.3 | Warm colors through the display gamma table, a "From… To…" schedule, a temperature slider |
| `com.skeuo4ever.newsash` — New App Sash | iOS 6 | The native "New" sash on every new app until its first launch — ipa and Cydia apps too, where iOS 6 never puts it |
| `com.skeuo4ever.boldtext` — Bold Text | iOS 7 | The system font and Helvetica one weight bolder in every app |
| `com.skeuo4ever.desktopsite` — Request Desktop Site | iOS 9 | A Request Desktop Site item in Safari's native share sheet |
| `com.skeuo4ever.core` | — | The **Settings → Skeuo4Ever** item and shared services; installed automatically |
| `com.skeuo4ever` | — | Meta package: every feature in one install; replaces the old iOS6Revive packages |

Each feature is a separate package; Settings → Skeuo4Ever shows only the installed ones.

**Language.** The interface is in English and Russian: by the system language, or chosen in
Settings → Skeuo4Ever → Language. Package pages switch the same way.

### How Low Power Mode works
Brightness drops by 20 % and Auto-Lock is set to 1 minute (the minimum in iOS 6). Turning the mode off
restores both unless you changed them by hand. While charging, the mode turns itself off once the battery
passes 80 %.

### Night Shift and safety
Before writing the gamma table, its format is checked (it differs between iOS 6 and iOS 7+). If the format is
unfamiliar, the feature turns itself off and says so in its settings — the display is not touched. The original
table is kept in `/var/mobile/Library/Skeuo4Ever/gamma-original.bin`. A restart always brings the usual colors back.

## Installation

Add this source in Cydia:

```
https://vdch00.github.io/Skeuo4Ever/
```

The repo page has an "Add to Cydia" button. GitHub Pages works over HTTPS only. If Cydia on iOS 6 cannot
connect, download the `.deb` files from the build artifacts (the Actions tab) or from
`https://vdch00.github.io/Skeuo4Ever/debs/` and install them by hand.

### Moving from iOS6Revive
The project used to be called iOS6Revive (`com.ios6revive.*`). Install the **Skeuo4Ever** package from the new
source: it replaces all the old packages, and Cydia removes them in the same step. Settings, Night Shift data and
Activator gestures carry over by themselves.

### Enabling publishing (once)
1. On the free plan, GitHub Pages works only for **public** repositories:
   Settings → General → Danger Zone → Change visibility → Public.
2. Push to `main`: the first build creates the `gh-pages` branch.
3. Settings → Pages → Build and deployment → Source: **Deploy from a branch**, branch `gh-pages`, folder `/ (root)`.

Only builds of the default branch write to `gh-pages`; builds of other branches and pull requests only check
that publishing would succeed.

## Building

You need [Theos](https://theos.dev), an iOS toolchain and `iPhoneOS10.3.sdk` from [theos/sdks](https://github.com/theos/sdks)
(the last SDK with 32-bit stubs). `.github/workflows/build.yml` installs all of it automatically.
`scripts/fix-sdk.py` puts the `objc_msgSend*_stret` symbols, which only the 32-bit runtime has, back into the
libobjc stubs; `build.sh` and `check.sh` run it themselves.

```bash
export THEOS=~/theos
./build.sh                     # every package → debs/ (+ debs/sources.json, the source fingerprints)
python3 scripts/make-repo.py   # update the repo in _site/ (a gh-pages working copy can live there)
scripts/check.sh               # quick check: armv7 / iOS 6 compile and every symbol present in the SDK stubs
python3 scripts/make-icons.py  # redraw the repo and package icons
```

## Publishing and versions

Modeled on [sqmrak/sqmrakdev](https://github.com/sqmrak/sqmrakdev): `main` holds the sources, `gh-pages` the
published repo. Every push to `main` builds the packages, adds new versions to `gh-pages` and publishes it on Pages.

- **A package's version is the `Version` field of its `control`.** Bump it to release the package.
- `gh-pages/published.json` remembers every released version: file, sha256 and source fingerprint.
  Rebuilding the same code changes nothing — Cydia never gets empty updates.
- If a package's sources changed but its `Version` did not, the build fails and names the package.
  Code in `shared/` and `common.mk` goes into every tweak, so bump every version after changing it.
- Old versions stay in the repo, so users can roll back.

## Layout

```
shared/          shared code (headers only): settings, state, language, iOS 6.1 private APIs
tweaks/core      S4ECore (SpringBoard) + S4ESettings (Settings)
tweaks/<feature> one tweak per feature, each with its own control and MobileSubstrate filter
meta/skeuo4ever  the meta package
repo/            static repo files: page, styles, language switch, CydiaIcon.png
icons/           package icons (scripts/make-icons.py)
depictions/      package pages in English and Russian (<package>.en.txt, <package>.ru.txt);
                 control holds a short English line, since Cydia on iOS 6 turns non-ASCII Description into "?"
scripts/         Packages/Release generation, icons, checks
```

**Settings and state.** The source of truth is `/var/mobile/Library/Preferences/com.skeuo4ever.plist`.
Settings and SpringBoard write it and post the `com.skeuo4ever/prefs-changed` Darwin notification. SpringBoard
publishes a short bit mask in the state of the `com.skeuo4ever/state` notification: App Store apps live in a
sandbox and may not be able to read the plist, so they take their flags from there.

**Language.** Every user-facing string is written as `S4E_L(@"English", @"Русский")` (`shared/S4EShared.h`).
The choice is the `Language` key (`auto`, `en`, `ru`); `auto` follows the system language.

**Settings sections from packages.** A package can install `/Library/Skeuo4Ever/Sections/<name>.plist`
(`order`, `title`, `footer`, `cells = ({ title, key, default })`; any text may be a `{ en, ru }` dictionary),
and its switches show up in Settings → Skeuo4Ever without a core update. The cursor and the screenshot preview
do it this way: `tweaks/<feature>/layout/`.

**Code.** Plain Objective-C with `MSHookMessageEx`, no Logos. That way every file is checked by a regular clang,
and all private classes are looked up with `objc_getClass` and called after `respondsToSelector:`: if something
is missing, the feature quietly turns off instead of crashing SpringBoard.

Further stages are in [ROADMAP.md](ROADMAP.md).
