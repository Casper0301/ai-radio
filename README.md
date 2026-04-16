# AI Radio

A tiny native macOS **menu bar app** for streaming AI-generated music radio and major Norwegian stations.

No browser tab. No Electron. ~300 KB native Swift binary that lives in your menu bar and gets out of the way.

![menu bar app](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple) ![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift) ![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

## What you get

- **39 AI-generated stations** from [musicradio.ai](https://musicradio.ai) — jazz, lofi, synthwave, ambient, classical, K-pop, and 30+ more
- **6 Norwegian radio stations** — NRK P1, P2, P3, P4 Norge, NRJ, P10 Country
- **Live "now playing"** track info that updates as songs change
- **Media key support** — F8 play/pause, F7/F9 cycle through stations
- **Control Center integration** — shows track info in macOS Control Center
- **Remembers** the last station you played and your volume

192 kbps MP3 / AAC across the board — same quality as the source streams.

## Install (one command)

```bash
curl -L https://github.com/Casper0301/ai-radio/releases/latest/download/AIRadio.zip -o /tmp/AIRadio.zip && \
  unzip -oq /tmp/AIRadio.zip -d /Applications/ && \
  xattr -cr "/Applications/AI Radio.app" && \
  open "/Applications/AI Radio.app"
```

The `xattr -cr` step removes the macOS quarantine flag (the app is ad-hoc signed, not notarized — this is fine for a free open-source app, but Gatekeeper would otherwise block it).

After running this, look in the top-right of your menu bar for a `((•))` radio-waves icon.

## Usage

- Click the menu bar icon → pick a station → it plays
- Stations are grouped by **AI Music** and **Norwegian Radio**
- The header line shows the currently playing track
- F8 (or your Mac's play/pause key) toggles playback
- F7 / F9 cycle to the previous / next station

## Build from source

Requires Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/Casper0301/ai-radio.git
cd ai-radio
./build.sh
open "AI Radio.app"
```

The build script produces a universal binary that runs on both Apple Silicon and Intel Macs.

## How it works

The 39 AI-music stations are served by an [AzuraCast](https://www.azuracast.com/) backend at `radio.musicradio.ai`, which exposes a fully public REST API at `/api/nowplaying`. The app uses that for the station list, stream URLs, and per-track metadata.

Norwegian stations are direct Icecast/HTTP audio streams (NRK CDN, P4 Group, Bauer Sharp Stream). Now-playing info comes from the inline Icy `StreamTitle` metadata in the audio stream itself, parsed by `AVPlayerItemMetadataOutput`.

Audio playback is plain `AVPlayer` — no third-party libraries, no audio engine code. macOS handles the streaming and codec work natively.

## Uninstall

```bash
rm -rf "/Applications/AI Radio.app"
defaults delete no.casperschive.airadio
```

## License

MIT — see [LICENSE](LICENSE).

---

Built by [Casper Schive](https://casperschive.no). More free tools at [dev.casperschive.no](https://dev.casperschive.no).
