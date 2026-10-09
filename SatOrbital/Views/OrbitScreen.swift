import SwiftUI

struct OrbitScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var tracking = TrackingStore()
    @AppStorage("showsOrbit") private var showsOrbit = true
    @AppStorage("showsFootprint") private var showsFootprint = true
    @AppStorage("globeStyle") private var globeStyleID = GlobeStyle.natural.rawValue
    private var globeStyle: GlobeStyle { GlobeStyle(rawValue: globeStyleID) ?? .natural }
    @AppStorage("showsStarlinks") private var showsStarlinks = true
    @AppStorage("hiddenSatelliteCategories") private var hiddenCategories = ""
    @AppStorage("orbitViewMode") private var orbitViewModeID = OrbitViewMode.earthFixed.rawValue
    @AppStorage("orbitShell") private var orbitShellID = OrbitShell.all.rawValue
    private var orbitViewMode: OrbitViewMode { OrbitViewMode(rawValue: orbitViewModeID) ?? .earthFixed }
    private var orbitShell: OrbitShell { OrbitShell(rawValue: orbitShellID) ?? .all }
    @AppStorage("observerPlace") private var observerPlaceValue = ""
    private var observerPlace: ObserverPlace? { ObserverPlace.restore(observerPlaceValue) }
    @State private var showsSky = false
    @State private var skyPlace: ObserverPlace?
    @State private var pendingSkyPlace: ObserverPlace?
    @State private var showsPlaceSelection = false
    @State private var isChoosingPlace = false
    @State private var pickedPlace: ObserverPlace?
    @State private var showsTimeControls = false
    @State private var timeAnchor = Date()
    @State private var timeOffset: Double = 0
    @State private var resetID = 0
    @State private var cameraCommand = GlobeView.CameraCommand()
    @State private var showsAbout = false
    @State private var showsSettings = false
    @State private var showsSearch = false
    @State private var pendingSearchTarget: SatelliteTarget?
    @State private var didChooseSearch = false
    @State private var detailsTarget: SatelliteTarget?
    @State private var isFollowing = false
    @State private var renderingError: String?

    private let accent = Color(red: 0.48, green: 0.87, blue: 0.77)
    private let background = Color(red: 0.018, green: 0.030, blue: 0.055)

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 620
            VStack(spacing: 0) {
                header(compact: compact)
                globe
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                dashboard(compact: compact)
            }
            .padding(.top, compact ? 8 : 16)
            .padding(.bottom, 12)
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(accent)
        .fullScreenCover(isPresented: $showsSky) {
            if let skyPlace { ObserverSkyView(tracking: tracking, place: skyPlace) }
        }
        .sheet(isPresented: $showsPlaceSelection, onDismiss: {
            if let place = pendingSkyPlace {
                skyPlace = place
                pendingSkyPlace = nil
                showsSky = true
            }
        }) {
            PlaceSelectionView(current: pickedPlace ?? observerPlace, hasSavedPlace: observerPlace != nil,
                onSave: { observerPlaceValue = $0.storedValue; pickedPlace = nil },
                onRemove: { observerPlaceValue = ""; pickedPlace = nil },
                onPick: {
                    showsPlaceSelection = false
                    pickedPlace = nil
                    isFollowing = false
                    detailsTarget = nil
                    isChoosingPlace = true
                    Task { await tracking.select(nil) }
                }, onViewSky: { place in
                    observerPlaceValue = place.storedValue
                    pickedPlace = nil
                    pendingSkyPlace = place
                    isChoosingPlace = false
                    isFollowing = false
                    detailsTarget = nil
                    Task { await tracking.select(nil) }
                    showsPlaceSelection = false
                })
        }
        .sheet(isPresented: $showsTimeControls) { timeControls }
        .sheet(isPresented: $showsAbout) { about }
        .sheet(isPresented: $showsSettings) { settings }
        .sheet(isPresented: $showsSearch, onDismiss: {
            guard didChooseSearch else { return }
            didChooseSearch = false
            choose(pendingSearchTarget, showDetails: pendingSearchTarget != nil)
        }) {
            SatelliteSearchView(selected: tracking.selected) { target in
                pendingSearchTarget = target
                didChooseSearch = true
                showsSearch = false
            }
        }
        .sheet(item: $detailsTarget) { target in
            SatelliteDetailsView(tracking: tracking, target: target, isFollowing: $isFollowing,
                                 closeSelection: { choose(nil) })
        }
        .onChange(of: showsStarlinks) { _, _ in applyFilters() }
        .onChange(of: hiddenCategories) { _, _ in applyFilters() }
        .onChange(of: orbitShellID) { _, _ in
            tracking.setOrbitShell(orbitShell)
            detailsTarget = nil
            isFollowing = false
            Task { await tracking.reloadVisible() }
        }
        .onChange(of: tracking.selected) { _, _ in isFollowing = false }
        .onChange(of: tracking.frames.isEmpty) { _, empty in
            if empty { isFollowing = false }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            tracking.setVisibleCategories(enabledCategories)
            tracking.setOrbitShell(orbitShell)
            if reduceMotion { await tracking.pauseForReducedMotion() }
            await tracking.run()
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { isFollowing = false; Task { await tracking.pauseForReducedMotion() } }
        }
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 24) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(accent)
                    Text("SAT / ORBITAL")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(2.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer()
                Button {
                    timeAnchor = tracking.now
                    timeOffset = min(max(tracking.displayDate.timeIntervalSince(timeAnchor), -86_400), 86_400)
                    showsTimeControls = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20, weight: .light))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Time controls")
                Button { showsSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .light))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Search satellites")
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20, weight: .light))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
                Button { showsAbout = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("About satellite tracking")
            }

        }
        .padding(.horizontal, 24)
    }

    private var globe: some View {
        GlobeView(
            frames: tracking.frames,
            selected: tracking.selected,
            isActive: scenePhase == .active && !showsSky,
            showsOrbit: showsOrbit,
            showsFootprint: showsFootprint,
            globeStyle: globeStyle,
            displayDate: tracking.displayDate,
            animationDate: tracking.now,
            playbackRate: tracking.playbackRate,
            isPlaying: tracking.isLive,
            viewMode: orbitViewMode,
            orbitShell: orbitShell,
            resetID: resetID,
            cameraCommand: cameraCommand,
            isFollowing: isFollowing,
            reduceMotion: reduceMotion,
            observerPlace: observerPlace,
            isChoosingPlace: isChoosingPlace,
            onPlacePicked: { place in
                isChoosingPlace = false
                pickedPlace = place
                showsPlaceSelection = true
            },
            onSelect: { isChoosingPlace = false; choose($0, showDetails: true) },
            onManualControl: { isFollowing = false },
            onFailure: { renderingError = $0 }
        )
        .overlay {
            if tracking.frames.isEmpty {
                VStack(spacing: 10) {
                    if tracking.isRefreshing { ProgressView().tint(accent) }
                    Text(tracking.targets.isEmpty ? (enabledCategories.isEmpty ? "No categories selected" : "No satellites in this view") : tracking.isRefreshing ? "Loading orbit…" : "Position unavailable")
                        .font(.subheadline.weight(.medium))
                    Text(tracking.targets.isEmpty ? "Choose another orbit shell or category in Settings." : tracking.freshness == .expired ? "Update orbital data to resume tracking." : "The Earth view is still available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(background.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(tracking.isLive ? accent : .gray).frame(width: 5, height: 5)
                    Text(tracking.modeLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if orbitViewMode != .earthFixed || orbitShell != .all {
                    Text(tracking.selected == nil ? "\(orbitViewMode.name) · \(orbitShell.name)" : orbitViewMode.name)
                        .font(.caption2).foregroundStyle(.white.opacity(0.55))
                }
                if !tracking.isCurrentTime {
                    Text(tracking.displayDate.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                }
                if let place = observerPlace {
                    Label(place.name + " · " + place.coordinates, systemImage: "mappin")
                        .font(.caption2).foregroundStyle(.pink)
                        .lineLimit(2)
                }
                if showsFootprint, tracking.selected != nil, tracking.frame != nil {
                    Label("Above-horizon footprint", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.38))
                }
            }
            .padding(.leading, 26)
            .padding(.top, 22)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Text(isChoosingPlace ? "TAP EARTH TO CHOOSE A PLACE" : isFollowing ? "FOLLOWING \(tracking.selectionName.uppercased())" : "TAP A SATELLITE   ·   DRAG TO ROTATE")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.40))
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                if isChoosingPlace { isChoosingPlace = false }
                else { pickedPlace = nil; showsPlaceSelection = true }
            } label: {
                Label(isChoosingPlace ? "Cancel" : "Place", systemImage: isChoosingPlace ? "xmark" : "mappin.and.ellipse")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(background.opacity(0.85), in: Capsule())
            }
            .accessibilityLabel(isChoosingPlace ? "Cancel choosing a place" : "Choose or edit observer place")
            .padding(.leading, 18).padding(.bottom, 34)
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                Picker("Orbit shell", selection: $orbitShellID) {
                    ForEach(OrbitShell.allCases) { shell in Text(shell.name).tag(shell.rawValue) }
                }
                Divider()
                Button("Rotate left", systemImage: "arrow.left") { moveCamera(yaw: -0.3) }
                Button("Rotate right", systemImage: "arrow.right") { moveCamera(yaw: 0.3) }
                Button("Look from north", systemImage: "arrow.up") { moveCamera(pitch: 0.3) }
                Button("Look from south", systemImage: "arrow.down") { moveCamera(pitch: -0.3) }
                Button("Zoom in", systemImage: "plus.magnifyingglass") { moveCamera(zoom: 0.8) }
                Button("Zoom out", systemImage: "minus.magnifyingglass") { moveCamera(zoom: 1.25) }
            } label: {
                Image(systemName: "viewfinder")
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 44, height: 44)
                    .background(background.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("View controls")
            .padding(.trailing, 18)
            .padding(.bottom, 34)
        }
    }

    private func dashboard(compact: Bool) -> some View {
        VStack(spacing: 14) {
            if let message = renderingError ?? tracking.predictionError ?? tracking.notice {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(3)
            } else if let selected = tracking.selected, tracking.freshness(for: selected) == .stale {
                Text("Elements are over 48 hours old. Position accuracy may be reduced.")
                    .font(.caption2).foregroundStyle(.orange)
            }

            if let selected = tracking.selected {
                HStack(spacing: 12) {
                    Button { choose(nil) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Close satellite selection")
                    .accessibilityHint("Returns to your previous globe rotation and zoom.")
                    Spacer(minLength: 0)
                    Button { isFollowing.toggle() } label: {
                        Label(isFollowing ? "Following" : "Follow", systemImage: isFollowing ? "location.fill" : "location")
                    }
                    .disabled(tracking.frame == nil || reduceMotion)
                    .accessibilityHint("Keeps the satellite centered. Dragging or pinching stops following.")
                    Spacer(minLength: 0)
                    Button(selected.name, systemImage: "info.circle") { detailsTarget = selected }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }

            HStack(spacing: 10) {
                Button { Task { await tracking.togglePlayback() } } label: {
                    Label(tracking.isLive ? "Pause" : "Resume", systemImage: tracking.isLive ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(background)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("playPause")
                .disabled(tracking.frames.isEmpty)
                Button {
                    Task { await tracking.returnToNow(); resetID += 1 }
                } label: {
                    Text("NOW")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 56, height: 46)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel(tracking.selected == nil ? "Return to current time and center Earth" : "Return to current time and center satellite")
                .disabled(tracking.frames.isEmpty)
                Button { showsOrbit.toggle() } label: {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 19))
                        .foregroundStyle(showsOrbit ? accent : .white.opacity(0.4))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel(showsOrbit ? "Hide orbit line" : "Show orbit line")
                Button { resetID += 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 17))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel(tracking.selected == nil ? "Center the view on Earth" : "Center the view on the satellite")
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Predicted position · CelesTrak orbital data")
                    if let epoch = tracking.cached?.elements.epoch {
                        Text("Element epoch: " + utcDate(epoch))
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Button { Task { await tracking.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .disabled(!tracking.canRefresh)
                .accessibilityLabel("Refresh orbital data")
                .accessibilityHint("Available once every 24 hours. See About for the next update time.")
            }
        }
        .padding(.horizontal, 24)
    }

    private func choose(_ target: SatelliteTarget?, showDetails: Bool = false) {
        isChoosingPlace = false
        isFollowing = false
        if let target {
            setCategory(target.filterCategory, visible: true)
            tracking.setVisibleCategories(enabledCategories)
        }
        if target == tracking.selected { resetID += 1 }
        if showDetails { detailsTarget = target } else { detailsTarget = nil }
        Task { await tracking.select(target) }
    }

    private func moveCamera(yaw: Float = 0, pitch: Float = 0, zoom: Float = 1) {
        isFollowing = false
        cameraCommand = .init(id: cameraCommand.id + 1, yaw: yaw, pitch: pitch, zoom: zoom)
    }

    private func utcDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    private var enabledCategories: Set<SatelliteCategory> {
        let hidden = Set(hiddenCategories.split(separator: ",").compactMap { SatelliteCategory(rawValue: String($0)) })
        var enabled = Set(SatelliteCategory.allCases).subtracting(hidden)
        if !showsStarlinks { enabled.remove(.starlink) }
        return enabled
    }

    private func setCategory(_ category: SatelliteCategory, visible: Bool) {
        if category == .starlink { showsStarlinks = visible; return }
        var hidden = Set(hiddenCategories.split(separator: ",").map(String.init))
        if visible { hidden.remove(category.rawValue) } else { hidden.insert(category.rawValue) }
        hiddenCategories = hidden.sorted().joined(separator: ",")
    }

    private func applyFilters() {
        tracking.setVisibleCategories(enabledCategories)
        if let target = detailsTarget, !enabledCategories.contains(target.filterCategory) { detailsTarget = nil }
        Task { await tracking.reloadVisible() }
    }

    private var timeControls: some View {
        NavigationStack {
            Form {
                Section("Displayed time") {
                    Text(tracking.displayDate.formatted(date: .abbreviated, time: .standard))
                        .font(.headline.monospacedDigit())
                    Text("Times use your local time zone. Positions and daylight are predictions from the current orbital data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Explore time") {
                    Text(timeAnchor.addingTimeInterval(timeOffset).formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                    Slider(value: $timeOffset, in: -86_400...86_400, step: 60) { editing in
                        if editing {
                            if tracking.isLive { Task { await tracking.togglePlayback() } }
                        } else { Task { await tracking.seek(to: timeAnchor.addingTimeInterval(timeOffset)) } }
                    }
                    .accessibilityLabel("Explore 24 hours before or after now")
                    HStack {
                        Text("−24 hours")
                        Spacer()
                        Text("+24 hours")
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("−15 min") { Task { await tracking.seek(to: tracking.displayDate.addingTimeInterval(-900)); syncTimeSlider() } }
                        Spacer()
                        Button("+15 min") { Task { await tracking.seek(to: tracking.displayDate.addingTimeInterval(900)); syncTimeSlider() } }
                    }.buttonStyle(.borderless)
                }
                Section("Playback") {
                    Picker("Speed", selection: Binding(
                        get: { tracking.playbackRate },
                        set: { rate in Task { await tracking.setPlaybackRate(rate) } }
                    )) {
                        Text("1×").tag(1.0)
                        Text("10×").tag(10.0)
                        Text("60×").tag(60.0)
                    }.pickerStyle(.segmented)
                    Button(tracking.isLive ? "Pause playback" : "Play from this time", systemImage: tracking.isLive ? "pause.fill" : "play.fill") {
                        Task { await tracking.togglePlayback(); syncTimeSlider() }
                    }.disabled(tracking.frames.isEmpty)
                    Button("Return to now", systemImage: "clock") {
                        Task { await tracking.returnToNow(); syncTimeSlider() }
                    }
                }
            }
            .navigationTitle("Time controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsTimeControls = false } } }
        }
        .tint(accent)
        .presentationDetents([.large])
    }

    private func syncTimeSlider() {
        timeAnchor = tracking.now
        timeOffset = min(max(tracking.displayDate.timeIntervalSince(timeAnchor), -86_400), 86_400)
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Orbit view") {
                    Picker("View mode", selection: $orbitViewModeID) {
                        ForEach(OrbitViewMode.allCases) { mode in Text(mode.name).tag(mode.rawValue) }
                    }
                    Text(orbitViewMode.description).font(.footnote).foregroundStyle(.secondary)
                    Picker("Orbit shell", selection: $orbitShellID) {
                        ForEach(OrbitShell.allCases) { shell in Text(shell.name).tag(shell.rawValue) }
                    }.pickerStyle(.segmented)
                    Text(orbitShell.description).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Globe style") {
                    Picker("Appearance", selection: $globeStyleID) {
                        ForEach(GlobeStyle.allCases) { style in
                            Text(style.name).tag(style.rawValue)
                        }
                    }
                    Text(globeStyle.description).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Globe display") {
                    Toggle("Show orbit lines", isOn: $showsOrbit)
                    Toggle("Show visibility footprint", isOn: $showsFootprint)
                }
                Section("Satellite categories") {
                    ForEach(SatelliteCategory.allCases) { category in
                        Toggle(category.name, isOn: Binding(
                            get: { enabledCategories.contains(category) },
                            set: { setCategory(category, visible: $0) }
                        ))
                    }
                    Button("Show all categories") { hiddenCategories = ""; showsStarlinks = true }
                    Text("Filters hide both markers and orbit lines. Search still includes every satellite; selecting one turns its category on.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Satellite models and orbits") {
                    ForEach(SatelliteKind.allCases) { kind in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(kind.name, systemImage: kind.symbol)
                            Text(kind.description).font(.caption).foregroundStyle(.secondary)
                            Text("\(kind.orbitColorName) orbit line").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Models show the type of object and are enlarged for easy tapping.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Visibility footprints") {
                    Text("Select a satellite to see its gold footprint on Earth. Inside the outline, that satellite is above the horizon for an observer at sea level.")
                    Text("A visible pass also depends on darkness, satellite illumination, brightness, weather, and your local horizon.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSettings = false } } }
        }
        .tint(accent)
        .presentationDetents([.large])
    }

    private var about: some View {
        NavigationStack {
            List {
                Section("Current orbital data") {
                    LabeledContent("Satellite", value: tracking.selected.map { "\($0.name) · NORAD \($0.id)" } ?? "All satellites")
                    if let cached = tracking.cached, let epoch = cached.elements.epoch {
                        LabeledContent("Element epoch", value: utcDate(epoch))
                        LabeledContent("Downloaded", value: utcDate(cached.fetchedAt))
                        LabeledContent("Source", value: cached.isBundled ? "Included CelesTrak snapshot" : "Saved CelesTrak download")
                        LabeledContent("Inclination", value: String(format: "%.4f°", cached.elements.inclination))
                        LabeledContent("Element age", value: String(format: "%.1f hours", abs(tracking.now.timeIntervalSince(epoch)) / 3600))
                    }
                    if tracking.nextRequestAt > tracking.now {
                        LabeledContent("Next update check", value: utcDate(tracking.nextRequestAt))
                    }
                    Button("Check for orbital update") { Task { await tracking.refresh() } }
                        .disabled(!tracking.canRefresh)
                    Text("Orbital downloads are limited to once every 24 hours during development, including after a failed attempt. Refresh and app restarts respect the same limit. Saved elements continue working offline.")
                    Text("Elements older than 48 hours are marked stale. Beyond seven days, positions are hidden until usable data is available. These are conservative app limits, not accuracy guarantees.")
                }
                Section("Exploring the orbit") {
                    Text("Drag to rotate, pinch to zoom, or use View controls. The center button points the globe at the selected satellite, or centers Earth in All mode. Use Search to find a satellite by name, alias, or NORAD ID. Settings offers Earth-fixed and Space-fixed motion, plus All, LEO, and Higher orbit views. The orbit-shell control is also in View controls. Search can focus a satellite outside the current shell; closing returns to the previous view. Time controls lets you explore a day before or after now and play at 1×, 10×, or 60×. Resume plays from the displayed time; NOW restores real time. Settings contains category filters, orbit lines, and the selected satellite’s above-horizon footprint. Selecting a Starlink in search turns its visibility back on. Tap a visible satellite to select it and open its details. Follow keeps it centered; dragging or pinching stops following. Close satellite selection returns to your previous globe rotation and zoom. The center button in All mode restores the default Earth overview. Satellite markers are enlarged for visibility.")
                    Text("Pause holds the displayed time. Resume and NOW return to the actual current time, including after the app has been in the background.")
                    Text("The highlighted loop approximates the selected satellite’s orbital ellipse. Earth rotation animates smoothly; the shape refreshes occasionally to account for orbital changes. It illustrates orbital shape, not the future path over Earth. Speed is measured in the inertial TEME frame; altitude is above the WGS84 ellipsoid.")
                }
                Section("How positions are calculated") {
                    Text("SGP4 predicts positions from public mean orbital elements. These are calculated positions, not live telemetry. Maneuvers and aging data can reduce accuracy. Natural and Blueprint shading approximates day and night at the displayed time; Atlas stays evenly lit. This does not predict satellite illumination or naked-eye visibility. The gold footprint marks where the selected satellite is above an ideal sea-level horizon. It does not account for terrain, atmospheric refraction, darkness, sunlight, or brightness; being above the horizon does not guarantee a visible object in the sky.")
                    Link("CelesTrak data and usage policy", destination: URL(string: "https://celestrak.org/usage-policy.php")!)
                    Text("SGP4: aholinch/sgp4, based on Vallado/CSSI, Unlicense. Library and fixture provenance are included with the project.")
                    Link("SGP4 source", destination: URL(string: "https://github.com/aholinch/sgp4")!)
                }
                Section("Earth imagery") {
                    Text("NASA Earth Observatory · Blue Marble: Next Generation. December 2004 composite. Credit: Reto Stöckli, NASA Earth Observatory.")
                    Link("About the imagery", destination: URL(string: "https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-map/")!)
                }
            }
            .navigationTitle("About satellite tracking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAbout = false } }
            }
        }
        .presentationDetents([.large])
    }

}

struct OrbitScreen_Previews: PreviewProvider {
    static var previews: some View { OrbitScreen().preferredColorScheme(.dark) }
}
