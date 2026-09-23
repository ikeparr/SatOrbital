import SwiftUI

struct OrbitScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var tracking = TrackingStore()
    @State private var showsOrbit = true
    @State private var resetID = 0
    @State private var cameraCommand = GlobeView.CameraCommand()
    @State private var showsAbout = false
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
        .sheet(isPresented: $showsAbout) { about }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if reduceMotion { await tracking.pauseForReducedMotion() }
            await tracking.run()
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { Task { await tracking.pauseForReducedMotion() } }
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
                }
                Spacer()
                Button { showsAbout = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("About ISS tracking")
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A new perspective.")
                        .font(.system(size: compact ? 25 : 32, weight: .medium, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if !compact {
                        Text("Explore the world from above.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 24)
    }

    private var globe: some View {
        GlobeView(
            frame: tracking.frame,
            isActive: scenePhase == .active,
            showsOrbit: showsOrbit,
            resetID: resetID,
            cameraCommand: cameraCommand,
            onFailure: { renderingError = $0 }
        )
        .overlay {
            if tracking.frame == nil {
                VStack(spacing: 10) {
                    if tracking.isRefreshing { ProgressView().tint(accent) }
                    Text(tracking.isRefreshing ? "Loading ISS orbit…" : "ISS position unavailable")
                        .font(.subheadline.weight(.medium))
                    Text(tracking.freshness == .expired ? "Update orbital data to resume tracking." : "The Earth view is still available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(background.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 7) {
                Circle().fill(tracking.freshness == .stale ? .orange : tracking.isLive ? accent : .gray).frame(width: 5, height: 5)
                Text(tracking.modeLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.leading, 26)
            .padding(.top, 22)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Text("DRAG TO ROTATE   ·   PINCH TO ZOOM")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.40))
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
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
            } else if tracking.freshness == .stale {
                Text("Elements are over 48 hours old. Position accuracy may be reduced.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                HStack(alignment: .center, spacing: 13) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 21))
                        .foregroundStyle(accent)
                        .frame(width: 46, height: 46)
                        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ISS")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("International Space Station · 25544")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                    Text("SGP4")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(accent.opacity(0.25)))
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    metric("ALTITUDE", value: formatted(tracking.frame?.state.altitudeKilometers, decimals: 1), unit: "km")
                    Spacer(minLength: 6)
                    metric("SPEED", value: formatted(tracking.frame?.state.speedKilometersPerSecond, decimals: 2), unit: "km/s")
                    Spacer(minLength: 6)
                    metric("ORBIT", value: formatted(tracking.cached.map { $0.elements.periodSeconds / 60 }, decimals: 1), unit: "min")
                }
                if let state = tracking.frame?.state {
                    HStack {
                        Text(String(format: "%.2f°%@  %.2f°%@", abs(state.latitude), state.latitude >= 0 ? "N" : "S", abs(state.longitude), state.longitude >= 0 ? "E" : "W"))
                        Spacer(minLength: 4)
                        Text(utcTime(state.date) + " UTC")
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .monospacedDigit()
                }
            }
            .padding(compact ? 16 : 20)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.075)))

            HStack(spacing: 10) {
                Button { Task { await tracking.togglePlayback() } } label: {
                    Label(tracking.isLive ? "Pause" : "Resume", systemImage: tracking.isLive ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(background)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("playPause")
                .disabled(tracking.frame == nil)
                Button {
                    Task { await tracking.returnToNow(); resetID += 1 }
                } label: {
                    Text("NOW")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 56, height: 46)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel("Return to current time and center ISS")
                .disabled(tracking.frame == nil)
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
                .accessibilityLabel("Center the view on the ISS")
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
                .accessibilityHint("Available every two hours. See About for the next update time.")
            }
        }
        .padding(.horizontal, 24)
    }

    private func metric(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.4))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .medium, design: .rounded))
                Text(unit).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit)")
    }

    private func moveCamera(yaw: Float = 0, pitch: Float = 0, zoom: Float = 1) {
        cameraCommand = .init(id: cameraCommand.id + 1, yaw: yaw, pitch: pitch, zoom: zoom)
    }

    private func formatted(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }
        return String(format: "%.*f", decimals, value)
    }

    private func utcTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func utcDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    private var about: some View {
        NavigationStack {
            List {
                Section("Current orbital data") {
                    LabeledContent("Satellite", value: "ISS · NORAD 25544")
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
                    Text("Updates are checked at most once every two hours after a successful download. Network or provider failures trigger a retry delay. Saved elements continue working offline.")
                    Text("Elements older than 48 hours are marked stale. Beyond seven days, positions are hidden until usable data is available. These are conservative app limits, not accuracy guarantees.")
                }
                Section("Exploring the orbit") {
                    Text("Drag to rotate, pinch to zoom, or use View controls. The center button points the globe at the ISS. The satellite marker is enlarged for visibility.")
                    Text("Pause holds the displayed time. Resume and NOW return to the actual current time, including after the app has been in the background.")
                    Text("The green loop shows the ISS’s current orbital ellipse and updates with its position. It illustrates the orbit’s shape, not its future path over Earth. Speed is measured in the inertial TEME frame; altitude is above the WGS84 ellipsoid.")
                }
                Section("How positions are calculated") {
                    Text("SGP4 predicts positions from public mean orbital elements. These are calculated positions, not live telemetry. Maneuvers and aging data can reduce accuracy. Earth lighting is illustrative; visibility footprints are not included yet.")
                    Link("CelesTrak data and usage policy", destination: URL(string: "https://celestrak.org/usage-policy.php")!)
                    Text("SGP4: aholinch/sgp4, based on Vallado/CSSI, Unlicense. Library and fixture provenance are included with the project.")
                    Link("SGP4 source", destination: URL(string: "https://github.com/aholinch/sgp4")!)
                }
                Section("Earth imagery") {
                    Text("NASA Earth Observatory · Blue Marble: Next Generation. December 2004 composite. Credit: Reto Stöckli, NASA Earth Observatory.")
                    Link("About the imagery", destination: URL(string: "https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-map/")!)
                }
            }
            .navigationTitle("About ISS tracking")
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
