import Cocoa
import AVFoundation
import MediaPlayer

// MARK: - Models

enum NowPlayingSource: Hashable {
    case azuracast(shortcode: String, baseURL: URL)
    case icyStream
}

struct Station: Hashable {
    let id: String
    let name: String          // raw name from source (used for now-playing fallback)
    let displayName: String   // shown in the menu (e.g. "Music Radio Jazz" → "Jazz")
    let genre: String         // group label, e.g. "Jazz & Blues", "Norwegian"
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

// MARK: - Genre map (AzuraCast shortcode → curated genre bucket)

enum Genres {
    /// Curator's grouping of musicradio.ai stations into genre buckets.
    static let aiMap: [String: String] = [
        // Mixed — the master stream that pulls from everything
        "musicradio.ai":              "Mixed",
        // Chill & Focus
        "music_radio_acoustic":       "Chill & Focus",
        "music_radio_ambient":        "Chill & Focus",
        "music_radio_chillout":       "Chill & Focus",
        "music_radio_focus_study":    "Chill & Focus",
        "music_radio_lo-fi":          "Chill & Focus",
        "music_radio_lounge":         "Chill & Focus",
        "music_radio_sleep":          "Chill & Focus",
        "music_radio_zen":            "Chill & Focus",
        "place_du_dauphine":          "Chill & Focus",
        "family_office_hq":           "Chill & Focus",
        // Electronic
        "music_radio_chillout_deep_house": "Electronic",
        "music_radio_dance":          "Electronic",
        "music_radio_disco":          "Electronic",
        "music_radio_drum__bass":     "Electronic",
        "music_radio_synthwave":      "Electronic",
        "music_radio_techno":         "Electronic",
        "music_radio_uk_garage":      "Electronic",
        // Hip-Hop & Soul
        "music_radio_acid_jazz":      "Hip-Hop & Soul",
        "music_radio_funk":           "Hip-Hop & Soul",
        "music_radio_hip_hop":        "Hip-Hop & Soul",
        "music_radio_rb__soul":       "Hip-Hop & Soul",
        // Rock & Metal
        "music_radio_grunge_rock":    "Rock & Metal",
        "music_radio_indie_alternative": "Rock & Metal",
        "music_radio_metal":          "Rock & Metal",
        "music_radio_rock":           "Rock & Metal",
        // Jazz & Blues
        "music_radio_blues":          "Jazz & Blues",
        "music_radio_jazz":           "Jazz & Blues",
        // Singletons
        "music_radio_classical":      "Classical",
        "music_radio_pop":            "Pop",
        "music_radio_country":        "Country",
        "music_radio_fitness":        "Fitness",
        "music_radio_gospel":         "Gospel",
        // World
        "music_radio_afrobeats":      "World",
        "music_radio_celtic":         "World",
        "music_radio_french_chanson": "World",
        "music_radio_k-pop":          "World",
        "music_radio_latin":          "World",
        "music_radio_reggae":         "World",
    ]

    /// Display order for groups in the Stations submenu.
    /// Norwegian first, then the Mixed all-genres stream, then alphabetical
    /// genre buckets, with "Other" / "Discover" last.
    static let order: [String] = [
        "Norwegian",
        "Mixed",
        "Chill & Focus",
        "Classical",
        "Country",
        "Electronic",
        "Fitness",
        "Gospel",
        "Hip-Hop & Soul",
        "Jazz & Blues",
        "Pop",
        "Rock & Metal",
        "World",
        "Other",
    ]

    static func bucket(for shortcode: String) -> String {
        aiMap[shortcode] ?? "Other"
    }

    /// "Music Radio Jazz" → "Jazz". Leaves names without the prefix untouched.
    /// Special-cases the master "MusicRadio.AI" stream to "All Genres".
    static func displayName(from raw: String, shortcode: String) -> String {
        if shortcode == "musicradio.ai" { return "All Genres" }
        let prefix = "Music Radio "
        if raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
        return raw
    }
}

// MARK: - Favorites

@MainActor
enum Favorites {
    private static let key = "favorite_station_ids"

    static var ids: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func contains(_ id: String) -> Bool { ids.contains(id) }

    static func toggle(_ id: String) -> Bool {
        var s = ids
        let nowPinned: Bool
        if s.contains(id) { s.remove(id); nowPinned = false }
        else { s.insert(id); nowPinned = true }
        UserDefaults.standard.set(Array(s).sorted(), forKey: key)
        return nowPinned
    }
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

    static func fetchStations(baseURL: URL) async throws -> [Station] {
        let url = baseURL.appendingPathComponent("api/nowplaying")
        let (data, _) = try await URLSession.shared.data(from: url)
        let raw = try JSONDecoder().decode([StationsResponse].self, from: data)
        return raw.map { r in
            let best = r.station.mounts.max(by: { $0.bitrate < $1.bitrate })
            let url = best?.url ?? r.station.listen_url
            let display = Genres.displayName(from: r.station.name, shortcode: r.station.shortcode)
            return Station(
                id: "azuracast:\(r.station.shortcode)",
                name: r.station.name,
                displayName: display,
                genre: Genres.bucket(for: r.station.shortcode),
                listenURL: url,
                bitrate: best?.bitrate ?? 0,
                format: best?.format ?? "mp3",
                nowPlayingSource: .azuracast(shortcode: r.station.shortcode, baseURL: baseURL)
            )
        }.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
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
            displayName: name,
            genre: "Norwegian",
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

    static let kEmail = "ai_radio_email"

    static var isActivated: Bool { UserDefaults.standard.string(forKey: kEmail) != nil }
    static var email: String? { UserDefaults.standard.string(forKey: kEmail) }

    static func sendCode(email: String) async throws {
        try await call(
            path: "send-marketplace-code",
            body: ["email": email]
        )
    }

    /// Verifies the 6-digit code against the marketplace_codes table.
    /// We discard the returned license_key — the code IS the activation.
    static func verifyCode(email: String, code: String) async throws {
        struct Resp: Decodable { let license_key: String? ; let error: String? }
        let data = try await call(
            path: "claim-free-license",
            body: ["email": email, "code": code, "product_slug": productSlug]
        )
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        if parsed.license_key != nil { return }
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

// MARK: - Text field with proper Cmd+V/C/X/A in NSAlert accessory view

/// NSTextField inside an NSAlert.accessoryView doesn't get standard editing
/// shortcuts (Cmd+V etc.) propagated through the responder chain. This subclass
/// catches them explicitly and forwards to the field editor.
final class PastableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if cmd {
            switch event.charactersIgnoringModifiers {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
            case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Custom station row view (label + clickable pin button)

/// Custom NSView used as `NSMenuItem.view` for station rows. Renders the
/// station name on the left and a clickable pin/unpin button on the right.
/// Click on the row body plays the station; click on the pin button toggles
/// the favorite without closing the menu.
@MainActor
final class StationRowView: NSView {
    let station: Station
    private let isLocked: Bool
    private let isCurrent: Bool
    private var isPinned: Bool
    private let onPlay: (Station) -> Void
    /// Returns the new pinned state (true = now pinned, false = now unpinned).
    private let onTogglePin: (Station) -> Bool

    private let leadingIndicator = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(station: Station,
         isPinned: Bool,
         isCurrent: Bool,
         isLocked: Bool,
         onPlay: @escaping (Station) -> Void,
         onTogglePin: @escaping (Station) -> Bool) {
        self.station = station
        self.isPinned = isPinned
        self.isCurrent = isCurrent
        self.isLocked = isLocked
        self.onPlay = onPlay
        self.onTogglePin = onTogglePin
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        autoresizingMask = [.width]

        // Leading "▶" indicator when this is the current station
        leadingIndicator.stringValue = isCurrent ? "▶" : ""
        leadingIndicator.font = .menuFont(ofSize: 0)
        leadingIndicator.alignment = .center
        leadingIndicator.drawsBackground = false
        leadingIndicator.isBordered = false
        leadingIndicator.isEditable = false
        leadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingIndicator)

        // Station name label
        label.stringValue = station.displayName
        label.font = .menuFont(ofSize: 0)
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Pin button
        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.isEnabled = !isLocked
        addSubview(pinButton)

        updatePinAppearance()
        applyTextColors(hovering: false)

        NSLayoutConstraint.activate([
            leadingIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingIndicator.widthAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: leadingIndicator.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),

            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 18),
            pinButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func updatePinAppearance() {
        let name = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: name, accessibilityDescription: isPinned ? "Unpin" : "Pin")
        pinButton.contentTintColor = isPinned ? .systemYellow : .tertiaryLabelColor
        pinButton.toolTip = isPinned ? "Unpin from Favorites" : "Pin to Favorites"
    }

    private func applyTextColors(hovering: Bool) {
        let base: NSColor
        if isLocked { base = .disabledControlTextColor }
        else if hovering { base = .selectedMenuItemTextColor }
        else { base = .controlTextColor }
        label.textColor = base
        leadingIndicator.textColor = base
        // Keep pin tint readable against the blue hover background
        if hovering && !isLocked && !isPinned {
            pinButton.contentTintColor = .selectedMenuItemTextColor
        } else {
            pinButton.contentTintColor = isPinned ? .systemYellow : .tertiaryLabelColor
        }
    }

    @objc private func pinClicked() {
        guard !isLocked else { return }
        isPinned = onTogglePin(station)
        updatePinAppearance()
        applyTextColors(hovering: isHovering)
        // Do NOT close the menu — let the user pin multiple stations in a row.
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        let pt = convert(event.locationInWindow, from: nil)
        // If the click is inside the pin button's frame, let NSButton handle it
        if pinButton.frame.insetBy(dx: -4, dy: -4).contains(pt) {
            super.mouseDown(with: event)
            return
        }
        // Otherwise: play the station and dismiss the menu
        onPlay(station)
        enclosingMenuItem?.menu?.cancelTrackingWithoutAnimation()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let ta = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyTextColors(hovering: true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTextColors(hovering: false)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering && !isLocked {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
        }
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
            let symbol = Activation.isActivated ? "dot.radiowaves.left.and.right" : "lock.fill"
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AI Radio")
            img?.isTemplate = true
            button.image = img
        }

        menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu

        let savedVolume = defaults.object(forKey: kVolume) as? Float ?? 0.8
        player.volume = savedVolume

        // Latency tuning for live radio streams. Default AVPlayer behavior is to
        // buffer ~10s of audio before starting playback so it never stalls — fine
        // for a downloaded MP4, terrible for "I clicked a radio station and want
        // sound now". Trading a tiny risk of a re-buffer event for instant start.
        player.automaticallyWaitsToMinimizeStalling = false

        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.rebuildMenu()
                self?.updateNowPlayingCenter()
            }
        }

        setupRemoteCommands()
        rebuildMenu(loading: true)
        Task { await loadStations() }

        // Auto-prompt activation on launch if not activated yet
        if !Activation.isActivated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showActivationFlow()
            }
        }
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let symbol = Activation.isActivated ? "dot.radiowaves.left.and.right" : "lock.fill"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AI Radio")
        img?.isTemplate = true
        button.image = img
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
            let ai = try await AzuraCast.fetchStations(baseURL: AzuraCast.musicRadioBase)
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
        guard Activation.isActivated else {
            showActivationFlow()
            return
        }
        if currentStation?.id == station.id, isPlaying { return }

        currentStation = station
        defaults.set(station.id, forKey: kLastStation)
        nowPlaying = nil
        rebuildMenu()

        // Use AVURLAsset with precise-duration disabled — for live Icecast streams
        // there's no useful duration to compute, and asking for it triggers extra
        // network probing before playback starts.
        let asset = AVURLAsset(url: station.listenURL, options: [
            "AVURLAssetPreferPreciseDurationAndTimingKey": false
        ])
        let item = AVPlayerItem(asset: asset)
        // Keep just enough buffered audio to play. Default is ~30–60s of forward
        // buffer, which delays the first audible sample.
        item.preferredForwardBufferDuration = 2

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
        let locked = !Activation.isActivated

        if locked {
            let title = NSMenuItem(title: "🔒  AI Radio is locked", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let sub = NSMenuItem(title: "    Activate with your email to unlock streaming.",
                                 action: nil, keyEquivalent: "")
            sub.isEnabled = false
            menu.addItem(sub)

            menu.addItem(NSMenuItem.separator())

            let activate = NSMenuItem(title: "✨ Activate AI Radio (free)",
                                      action: #selector(showActivationFlow),
                                      keyEquivalent: "")
            activate.target = self
            menu.addItem(activate)
            menu.addItem(NSMenuItem.separator())
        }

        // Header: current station + state
        if let cur = currentStation {
            let stateIcon: String = isPlaying ? "♪" : "■"
            let header = NSMenuItem(title: "\(stateIcon)  \(cur.displayName)", action: nil, keyEquivalent: "")
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
            toggle.isEnabled = !locked
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

        // Stations submenu — grouped by genre, with Favorites pinned at top
        if !stations.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let stationsItem = NSMenuItem(title: "Stations  (\(stations.count))", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false

            let favIds = Favorites.ids
            let pinned = stations.filter { favIds.contains($0.id) }
                                 .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }

            // ★ Favorites section (only shown if any pinned)
            if !pinned.isEmpty {
                let header = NSMenuItem(title: "— ★ FAVORITES  (\(pinned.count)) —",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                submenu.addItem(header)
                for s in pinned { submenu.addItem(makeStationItem(s, locked: locked, isFavorite: true)) }
                submenu.addItem(NSMenuItem.separator())
            }

            // Genre sections in curated order
            let byGenre = Dictionary(grouping: stations, by: { $0.genre })
            for genre in Genres.order {
                guard let inGenre = byGenre[genre], !inGenre.isEmpty else { continue }
                // Norwegian keeps insertion order; everything else is alphabetical
                let sorted = (genre == "Norwegian") ? inGenre : inGenre.sorted {
                    $0.displayName.lowercased() < $1.displayName.lowercased()
                }
                let header = NSMenuItem(title: "— \(genre.uppercased())  (\(sorted.count)) —",
                                        action: nil, keyEquivalent: "")
                header.isEnabled = false
                submenu.addItem(header)
                for s in sorted {
                    submenu.addItem(makeStationItem(s, locked: locked, isFavorite: favIds.contains(s.id)))
                }
                submenu.addItem(NSMenuItem.separator())
            }
            // Trim trailing separator
            if let last = submenu.items.last, last.isSeparatorItem {
                submenu.removeItem(last)
            }

            stationsItem.submenu = submenu
            stationsItem.isEnabled = !locked
            menu.addItem(stationsItem)

            let refresh = NSMenuItem(title: "Refresh Stations",
                                     action: #selector(refreshStationsAction),
                                     keyEquivalent: "")
            refresh.target = self
            refresh.isEnabled = !locked
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
            mi.isEnabled = !locked
            volMenu.addItem(mi)
        }
        volItem.submenu = volMenu
        volItem.isEnabled = !locked
        menu.addItem(volItem)

        // Open in browser (AzuraCast stations only — open the public player; Norwegian stations don't need it)
        if let cur = currentStation, case let .azuracast(shortcode, baseURL) = cur.nowPlayingSource {
            let openItem = NSMenuItem(title: "Open \(cur.displayName) in Browser",
                                      action: #selector(openInBrowser(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = baseURL.appendingPathComponent("public/\(shortcode)")
            menu.addItem(openItem)
        }

        // Activation status (only shown when activated; locked-state UI is at the top)
        if Activation.isActivated {
            menu.addItem(NSMenuItem.separator())
            let activated = NSMenuItem(
                title: "✓ Activated\(Activation.email.map { " — \($0)" } ?? "")",
                action: nil, keyEquivalent: ""
            )
            activated.isEnabled = false
            menu.addItem(activated)
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
        alert.informativeText = "Enter your email — we'll send a 6-digit code to your inbox to unlock streaming."
        alert.addButton(withTitle: "Send code")
        alert.addButton(withTitle: "Cancel")

        let field = PastableTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "you@example.com"
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
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
        alert.informativeText = "We sent a 6-digit code to \(email). Paste it below (Cmd+V works). It expires in 10 minutes."
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")

        let field = PastableTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        field.placeholderString = "123456"
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Tolerate spaces and stray characters from copy-paste; pull just the digits
        let raw = field.stringValue
        let digits = raw.filter(\.isNumber)
        guard digits.count == 6 else {
            showError(message: "The code should be 6 digits.")
            return
        }

        Task { @MainActor in
            do {
                try await Activation.verifyCode(email: email, code: digits)
                UserDefaults.standard.set(email, forKey: Activation.kEmail)
                self.updateMenuBarIcon()
                self.rebuildMenu()
                self.showSuccess(email: email)
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
    private func showSuccess(email: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "AI Radio activated"
        alert.informativeText = "You're set, \(email). Streaming is now unlocked — pick a station from the menu bar."
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func formatNowPlaying(_ np: NowPlayingInfo) -> String {
        let artist = np.artist.trimmingCharacters(in: .whitespaces)
        let title = np.title.trimmingCharacters(in: .whitespaces)
        if artist.isEmpty { return title.isEmpty ? "Live stream" : title }
        if title.isEmpty { return artist }
        return "\(artist) — \(title)"
    }

    // MARK: - Menu Actions

    /// Builds an NSMenuItem whose `.view` is a custom `StationRowView`
    /// (label + clickable pin button).
    private func makeStationItem(_ s: Station, locked: Bool, isFavorite: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: s.displayName, action: nil, keyEquivalent: "")
        item.representedObject = s
        let row = StationRowView(
            station: s,
            isPinned: isFavorite,
            isCurrent: s.id == currentStation?.id,
            isLocked: locked,
            onPlay: { [weak self] station in self?.play(station: station) },
            onTogglePin: { [weak self] station -> Bool in
                guard let self else { return false }
                let nowPinned = Favorites.toggle(station.id)
                // Rebuild the top-level menu so the "★ FAVORITES" section refreshes
                // next time the user opens the menu. Safe to call here — the menu
                // is still open; we're just rebuilding the model.
                self.rebuildMenu()
                return nowPinned
            }
        )
        item.view = row
        return item
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
        guard Activation.isActivated, !stations.isEmpty else { return }
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
            MPMediaItemPropertyTitle: nowPlaying.map { formatNowPlaying($0) } ?? cur.displayName,
            MPMediaItemPropertyArtist: cur.displayName,
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
