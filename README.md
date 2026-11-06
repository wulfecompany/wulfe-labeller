# Wülfe Labeller

A tiny macOS app that relabels PDF metadata. Drop in one or more PDFs and each file is updated in place:

- **Author, Creator and Producer** are set to your company name (default "Wülfe Company", changeable in Settings with ⌘,)
- **Keywords** are removed (Canva stores its design IDs here)
- Any other mention of **Canva** in the file info is replaced with your company name
- The **modified date** is set to now
- The macOS **"Where from"** download info and quarantine flag are stripped

Page content is never touched. When the new metadata fits in the space the old metadata used, it is overwritten in place, so the file stays the same size and nothing of the old values remains. Otherwise the new metadata is appended as a standard PDF incremental update and the old copy is blanked out. Every file is checked in memory before it's written, so a PDF the app can't handle is left unchanged.

## Install

1. Download `Wulfe-Labeller.zip` from the [latest release](https://github.com/wulfecompany/wulfe-labeller/releases/latest).
2. Unzip it and drag **Wülfe Labeller** to your Applications folder.
3. Open it. The first time, macOS will say it can't verify the developer: go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

The app checks for updates each time it launches, and from **Wülfe Labeller → Check for Updates…**. Updates install themselves and relaunch the app.

Requires macOS 14 (Sonoma) or later on an Apple Silicon or Intel Mac.

## Building

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This produces `build/Wülfe Labeller.app` and `build/Wulfe-Labeller.zip`.

## Releasing an update

Commit your changes, then:

```bash
./release.sh 1.2 "What changed"
```

This bumps the version, builds, tags, pushes, and publishes a GitHub Release with the zip attached. Everyone's app picks it up on its next launch.
