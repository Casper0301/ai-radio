import Cocoa
import AVFoundation
import MediaPlayer

// MARK: - Models

enum StationGroup: String, CaseIterable, Hashable {
    case aiMusic = "AI Music"
    case norwegian = "Norwegian Radio"
}

enum NowPlayingSource: Hashable {
    case azuracast(shortcode: String, baseURL: URL)
    case icyStream
}

struct Station: Hashable {
    let id: String
    let name: String
    let group: StationGroup
    let listenURL: URL
    let bitrate: Int
    let format: String
    let nowPlayingSource: NowPlayingSource
}

struct NowPlayingInfo: Equatable {
    let artist: String
    let title: String
    let artURL: URL?
}

// MARK: - AzuraCast API

enum AzuraCast {
    static let musicRadioBase = URL(string: "https://radio.musicradio.ai")!

    private struct StationsResponse: Decodable {
        let station: StationDTO
        struct StationDTO: Decodable {
            let id: Int
            let name: String
            let shortcode: String
            let listen_url: URL
            let mounts: [Mount]
        }
        struct Mount: Decodable {
            let url: URL
            let bitrate: Int
            let format: String
            let is_default: Bool
        }
    }

    private struct NPResponse: Decodable {
        let now_playing: NP
        struct NP: Decodable { let song: Song }
        struct Song: Decodable {
            let artist: String
            let title: String
            let art: URL?
        }
    }

    static func fetchStations(baseURL: URL, group: StationGroup) async throws -> [Station] {
        let url = baseURL.appendingPathComponent("api/nowplaying")
        let (data, _) = try await URLSession.shared.data(from: url)
        let raw = try JSONDecoder().decode([StationsResponse].self, from: data)
        return raw.map { r in
            let best = r.station.mounts.max(by: { $0.bitrate < $1.bitrate })
            let url = best?.url ?? r.station.listen_url
            return Station(
                id: "azuracast:\(r.station.shortcode)",
                name: r.station.name,
                group: group,
                listenURL: url,
                bitrate: best?.bitrate ?? 0,
                format: best?.format ?? "mp3",
                nowPlayingSource: .azuracast(shortcode: r.station.shortcode, baseURL: baseURL)
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func fetchNowPlaying(baseURL: URL, shortcode: String) async throws -> NowPlayingInfo {
        let url = baseURL.appendingPathComponent("api/nowplaying/\(shortcode)")
        let (data, _) = try await URLSession.shared.data(from: url)
        let r = try JSONDecoder().decode(NPResponse.self, from: data)
        let s = r.now_playing.song
        return NowPlayingInfo(artist: s.artist, title: s.title, artURL: s.art)
    }
}

// MARK: - Norwegian Radio (curated)

enum NorwegianRadio {
    static let stations: [Station] = [
        s("no:nrk_p1", "NRK P1",  "https://cdn0-47115-liveicecast0.dna.contentdelivery.net/p1_mp3_h",  192, "mp3"),
        s("no:nrk_p2", "NRK P2",  "https://cdn0-47115-liveicecast0.dna.contentdelivery.net/p2_aac_h",  159, "aac"),
        s("no:nrk_p3", "NRK P3",  "https://cdn0-47115-liveicecast0.dna.contentdelivery.net/p3_mp3_h",  192, "mp3"),
        s("no:p4",     "P4 Norge","https://p4.p4groupaudio.com/P04_AH",                                192, "aac"),
        s("no:nrj",    "NRJ Norge","https://live-bauerno.sharp-stream.com/kiss_no_mp3",               128, "mp3"),
        s("no:p10",    "P10 Country","https://p10.p4groupaudio.com/P10_AH",                           191, "aac"),
    ]

    private static func s(_ id: String, _ name: String, _ url: String, _ bitrate: Int, _ format: String) -> Station {
        Station(
            id: id,
            name: name,
            group: .norwegian,
            listenURL: URL(string: url)!,
            bitrate: bitrate,
            format: format,
            nowPlayingSource: .icyStream
        )
    }
}

// MARK: - Activation (email capture + free license key)

enum ActivationError: LocalizedError {
    case server(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .server(let m), .empty(let m): return m
        }
    }
}

@MainActor
enum Activation {
    static let supabaseURL = "https://wavpeucoanpboqsthujf.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhdnBldWNvYW5wYm9xc3RodWpmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU5ODg3MTUsImV4cCI6MjA5MTU2NDcxNX0.Ald3JKaGxtdFRtNvm7RddzdBOc6kQO1UIT7rjsJlZZU"
    static let productSlug = "ai-radio"

    static let kLicenseKey = "ai_radio_license_key"
    static let kEmail = "ai_radio_email"

    static var isActivated: Bool { UserDefaults.standard.string(forKey: kLicenseKey) != nil }
    static var email: String? { UserDefaults.standard.string(forKey: kEmail) }

    static func sendCode(email: String) async throws {
        try await call(
            path: "send-marketplace-code",
            body: ["email": email]
        )
    }

    static func claimLicense(email: String, code: String) async throws -> String {
        struct Resp: Decodable { let license_key: String? ; let error: String? }
        let data = try await call(
            path: "claim-free-license",
            body: ["email": email, "code": code, "product_slug": productSlug]
        )
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        if let key = parsed.license_key { return key }
        throw ActivationError.server(parsed.error ?? "Activation failed")
    }

    @discardableResult
    private static func call(path: String, body: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(supabaseURL)/functions/v1/\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Try to surface the server's error message
            struct ErrResp: Decodable { let error: String? }
            if let e = try? JSONDecoder().decode(ErrResp.self, from: data), let msg = e.error {
                throw ActivationError.server(msg)
            }
            throw ActivationError.server("Server error \(http.statusCode)")
        }
        return data
    }
}

// MARK: - Icy Metadata Observer

@MainActor
protocol IcyMetadataReceiver: AnyObject {
    func icyMetadataReceived(_ raw: String, for stationID: String)
}

final class IcyMetadataDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    weak var receiver: (any IcyMetadataReceiver)?
    let stationID: String

    init(receiver: any IcyMetadataReceiver, stationID: String) {
        self.receiver = receiver
        self.stationID = stationID
    }

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                                    didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        let title: String? = groups
            .flatMap { $0.items }
            .compactMap { $0.value(forKeyPath: "value") as? String ?? $0.stringValue }
            .first { !$0.isEmpty }
        guard let title else { return }
        let captured = title
        let sid = stationID
        Task { @MainActor [weak self] in
            self?.receiver?.icyMetadataReceived(captured, for: sid)
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, IcyMetadataReceiver {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let player = AVPlayer()

    private var stations: [Station] = []
    private var currentStation: Station?
    private var nowPlaying: NowPlayingInfo?
    private var refreshTimer: Timer?
    private var rateObserver: NSKeyValueObservation?
    private var icyDelegate: IcyMetadataDelegate?

    private let defaults = UserDefaults.standard
    private let kLastStation = "lastStationID"
    private let kVolume = "volume"

    private var isPlaying: Bool {
        player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                              accessibilityDescription: "Music Radio")
            img?.isTemplate = true
            button.image = img
        }

        menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu

        let savedVolume = defaults.object(forKey: kVolume) as? Float ?? 0.8
        player.volume = savedVolume

        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.rebuildMenu()
                self?.updateNowPlayingCenter()
            }
        }

        setupRemoteCommands()
        rebuildMenu(loading: true)
        Task { await loadStations() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        player.pause()
        refreshTimer?.invalidate()
    }

    // MARK: - Loading

    private func loadStations() async {
        // Norwegian stations are static; AzuraCast is fetched.
        var combined = NorwegianRadio.stations
        do {
            let ai = try await AzuraCast.fetchStations(baseURL: AzuraCast.musicRadioBase, group: .aiMusic)
            combined.append(contentsOf: ai)
            self.stations = combined
            if let last = defaults.string(forKey: kLastStation),
               let match = combined.first(where: { $0.id == last }) {
                self.currentStation = match
            }
            rebuildMenu()
            if let cur = currentStation {
                await refreshNowPlaying(for: cur)
            }
        } catch {
            // Even if AzuraCast fails, keep Norwegian stations available.
            self.stations = combined
            NSLog("AzuraCast load failed: \(error)")
            rebuildMenu()
        }
    }

    private func refreshNowPlaying(for station: Station) async {
        guard case let .azuracast(shortcode, baseURL) = station.nowPlayingSource else {
            // Icy metadata arrives via delegate; nothing to fetch.
            return
        }
        do {
            let np = try await AzuraCast.fetchNowPlaying(baseURL: baseURL, shortcode: shortcode)
            guard self.currentStation?.id == station.id else { return }
            self.nowPlaying = np
            rebuildMenu()
            updateNowPlayingCenter()
        } catch {
            NSLog("now-playing fetch failed: \(error)")
        }
    }

    // MARK: - IcyMetadataReceiver

    func icyMetadataReceived(_ raw: String, for stationID: String) {
        guard self.currentStation?.id == stationID else { return }
        // StreamTitle is usually "Artist - Title" but sometimes just "Title"
        let parts = raw.components(separatedBy: " - ")
        let info: NowPlayingInfo
        if parts.count >= 2 {
            info = NowPlayingInfo(artist: parts[0], title: parts.dropFirst().joined(separator: " - "), artURL: nil)
        } else {
            info = NowPlayingInfo(artist: "", title: raw, artURL: nil)
        }
        if info != self.nowPlaying {
            self.nowPlaying = info
            rebuildMenu()
            updateNowPlayingCenter()
        }
    }

    // MARK: - Playback

    private func play(station: Station) {
        if currentStation?.id == station.id, isPlaying { return }

        currentStation = station
        defaults.set(station.id, forKey: kLastStation)
        nowPlaying = nil
        rebuildMenu()

        // Cache-bust query so AVPlayer doesn't try to range-request a live stream
        var comps = URLComponents(url: station.listenURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970)))]
        let item = AVPlayerItem(url: comps.url ?? station.listenURL)

        // Hook up Icy metadata for non-AzuraCast streams
        if case .icyStream = station.nowPlayingSource {
            let delegate = IcyMetadataDelegate(receiver: self, stationID: station.id)
            let output = AVPlayerItemMetadataOutput(identifiers: nil)
            output.setDelegate(delegate, queue: .main)
            item.add(output)
            self.icyDelegate = delegate
        } else {
            self.icyDelegate = nil
        }

        player.replaceCurrentItem(with: item)
        player.play()

        startRefreshTimer()
        Task { await refreshNowPlaying(for: station) }
    }

    private func togglePlayPause() {
        guard let cur = currentStation else { return }
        if isPlaying {
            player.pause()
            refreshTimer?.invalidate()
        } else {
            play(station: cur)
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let cur = self.currentStation, self.isPlaying else { return }
                await self.refreshNowPlaying(for: cur)
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu(loading: Bool = false, error: Error? = nil) {
        menu.removeAllItems()

        // Header: current station + state
        if let cur = currentStation {
            let stateIcon: String = isPlaying ? "♪" : "■"
            let header = NSMenuItem(title: "\(stateIcon)  \(cur.name)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            if let np = nowPlaying {
                let line = formatNowPlaying(np)
                let item = NSMenuItem(title: "    \(line)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else if isPlaying {
                let item = NSMenuItem(title: "    Loading…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())

            let toggle = NSMenuItem(
                title: isPlaying ? "Pause" : "Play",
                action: #selector(togglePlayPauseAction),
                keyEquivalent: " "
            )
            toggle.target = self
            menu.addItem(toggle)
        } else if loading && stations.isEmpty {
            let item = NSMenuItem(title: "Loading stations…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if let error {
            let item = NSMenuItem(title: "Error: \(error.localizedDescription)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Stations submenu — grouped
        if !stations.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let stationsItem = NSMenuItem(title: "Stations  (\(stations.count))", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for group in StationGroup.allCases {
                let inGroup = stations.filter { $0.group == group }
                guard !inGroup.isEmpty else { continue }

                let header = NSMenuItem(title: "— \(group.rawValue.uppercased())  (\(inGroup.count)) —",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                submenu.addItem(header)

                for s in inGroup {
                    let item = NSMenuItem(title: s.name,
                                          action: #selector(stationSelected(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = s
                    if s.id == currentStation?.id { item.state = .on }
                    submenu.addItem(item)
                }
                submenu.addItem(NSMenuItem.separator())
            }
            // Trim trailing separator
            if let last = submenu.items.last, last.isSeparatorItem {
                submenu.removeItem(last)
            }
            stationsItem.submenu = submenu
            menu.addItem(stationsItem)

            let refresh = NSMenuItem(title: "Refresh Stations",
                                     action: #selector(refreshStationsAction),
                                     keyEquivalent: "")
            refresh.target = self
            menu.addItem(refresh)
        }

        // Volume submenu
        menu.addItem(NSMenuItem.separator())
        let volItem = NSMenuItem(title: "Volume  (\(Int(player.volume * 100))%)",
                                 action: nil, keyEquivalent: "")
        let volMenu = NSMenu()
        for v in [0, 25, 50, 75, 100] {
            let f = Float(v) / 100.0
            let title = v == 0 ? "Mute" : "\(v)%"
            let mi = NSMenuItem(title: title, action: #selector(setVolume(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = f
            if abs(player.volume - f) < 0.05 { mi.state = .on }
            volMenu.addItem(mi)
        }
        volItem.submenu = volMenu
        menu.addItem(volItem)

        // Open in browser (AzuraCast stations only — open the public player; Norwegian stations don't need it)
        if let cur = currentStation, case let .azuracast(shortcode, baseURL) = cur.nowPlayingSource {
            let openItem = NSMenuItem(title: "Open \(cur.name) in Browser",
                                      action: #selector(openInBrowser(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = baseURL.appendingPathComponent("public/\(shortcode)")
            menu.addItem(openItem)
        }

        // Activation
        menu.addItem(NSMenuItem.separator())
        if Activation.isActivated {
            let activated = NSMenuItem(
                title: "✓ Activated\(Activation.email.map { " — \($0)" } ?? "")",
                action: nil, keyEquivalent: ""
            )
            activated.isEnabled = false
            menu.addItem(activated)
        } else {
            let activate = NSMenuItem(
                title: "✨ Activate AI Radio (free)",
                action: #selector(showActivationFlow),
                keyEquivalent: ""
            )
            activate.target = self
            menu.addItem(activate)
        }

        // Quit
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit AI Radio", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Activation UI

    @objc private func showActivationFlow() {
        let alert = NSAlert()
        alert.messageText = "Activate AI Radio"
        alert.informativeText = "Enter your email to get a free license key. We'll send a 6-digit verification code to your inbox."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "you@example.com"
        if let prefilled = Activation.email { field.stringValue = prefilled }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let email = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains(".") else {
            showError(message: "That doesn't look like a valid email address.")
            return
        }

        Task { @MainActor in
            do {
                try await Activation.sendCode(email: email)
                self.showCodeEntry(email: email)
            } catch {
                self.showError(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func showCodeEntry(email: String) {
        let alert = NSAlert()
        alert.messageText = "Check your email"
        alert.informativeText = "We sent a 6-digit code to \(email). It expires in 10 minutes."
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        field.placeholderString = "123456"
        field.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, Int(code) != nil else {
            showError(message: "The code should be 6 digits.")
            return
        }

        Task { @MainActor in
            do {
                let key = try await Activation.claimLicense(email: email, code: code)
                UserDefaults.standard.set(key, forKey: Activation.kLicenseKey)
                UserDefaults.standard.set(email, forKey: Activation.kEmail)
                self.rebuildMenu()
                self.showSuccess(email: email, key: key)
            } catch {
                self.showError(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func showError(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't activate"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @MainActor
    private func showSuccess(email: String, key: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AI Radio activated"
        alert.informativeText = "You're set, \(email). Your license key is below — keep it safe (we'll re-send it any time you activate again with the same email).\n\n\(key)"
        alert.addButton(withTitle: "Copy key")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
        }
    }

    private func formatNowPlaying(_ np: NowPlayingInfo) -> String {
        let artist = np.artist.trimmingCharacters(in: .whitespaces)
        let title = np.title.trimmingCharacters(in: .whitespaces)
        if artist.isEmpty { return title.isEmpty ? "Live stream" : title }
        if title.isEmpty { return artist }
        return "\(artist) — \(title)"
    }

    // MARK: - Menu Actions

    @objc private func stationSelected(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Station else { return }
        play(station: s)
    }

    @objc private func togglePlayPauseAction() { togglePlayPause() }

    @objc private func refreshStationsAction() {
        Task { await loadStations() }
    }

    @objc private func setVolume(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Float else { return }
        player.volume = v
        defaults.set(v, forKey: kVolume)
        rebuildMenu()
    }

    @objc private func openInBrowser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Now Playing Info (Control Center / media keys)

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isPlaying, let cur = self.currentStation { self.play(station: cur) }
            }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause(); self?.refreshTimer?.invalidate() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.cycleStation(direction: 1) }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.cycleStation(direction: -1) }
            return .success
        }
    }

    private func cycleStation(direction: Int) {
        guard !stations.isEmpty else { return }
        let idx: Int
        if let cur = currentStation, let i = stations.firstIndex(where: { $0.id == cur.id }) {
            idx = (i + direction + stations.count) % stations.count
        } else {
            idx = 0
        }
        play(station: stations[idx])
    }

    private func updateNowPlayingCenter() {
        let center = MPNowPlayingInfoCenter.default()
        guard let cur = currentStation else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        let info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.map { formatNowPlaying($0) } ?? cur.name,
            MPMediaItemPropertyArtist: cur.name,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if let artURL = nowPlaying?.artURL {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: artURL),
                   let img = NSImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    await MainActor.run {
                        var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        current[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                    }
                }
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}

// MARK: - Bootstrap

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
