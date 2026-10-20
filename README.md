# WhoRuns

See who runs on your Mac.

WhoRuns is a menu bar app that lists every running process, grouped by the app or vendor that owns it. Each binary gets checked against its code signature, so you can tell in one look what belongs to Apple, what belongs to Slack, and what is unsigned.

## Install

Grab `WhoRuns.dmg` from [releases](https://github.com/ronakforcast/WhoRuns/releases), open it, and drag WhoRuns into Applications.

macOS blocks the first launch because the app is self-signed. Right-click WhoRuns in Applications and choose **Open**, twice. If you prefer Terminal, run this once and launch normally:

```
xattr -dr com.apple.quarantine /Applications/WhoRuns.app
```

You need macOS 13 or later. The build is universal, so Apple silicon and Intel both work.

## What you get

- Every process grouped by owner, with real app icons
- A RAM distribution strip that shows who holds your memory
- The code signature for every non-Apple binary, cached on disk so repeat scans are instant
- Unsigned binaries flagged in red
- Search, scope filters, and sorting by memory, CPU, or name
- Kill a single process, or every process owned by one app, with confirmation

## How it works

WhoRuns reads the process table with `ps` and verifies signatures with `codesign`. Both tools ship with macOS. Nothing leaves your machine: the app makes no network requests, and the only file it writes is a signature cache in `~/Library/Application Support/WhoRuns`.

## Build from source

```
git clone https://github.com/ronakforcast/WhoRuns.git
cd WhoRuns
./make-app.sh
open build/WhoRuns.app
```

Xcode Command Line Tools are required (`xcode-select --install`).

To build a universal `.dmg` yourself:

```
./make-dmg.sh 1.0.0
```

## License

MIT
