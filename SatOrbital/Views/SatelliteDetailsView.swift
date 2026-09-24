import SwiftUI

struct SatelliteDetailsView: View {
    @ObservedObject var tracking: TrackingStore
    let target: SatelliteTarget
    @Binding var isFollowing: Bool
    let returnToAll: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cached: CachedOrbit? { tracking.results[target]?.cached }
    private var state: OrbitalState? { tracking.frame(for: target)?.state }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(target.subtitle).font(.headline)
                    LabeledContent("NORAD catalog ID", value: String(target.id))
                    if let cached { LabeledContent("Catalog name", value: cached.elements.name) }
                }
                Section(tracking.isLive ? "Current predicted position" : "Paused predicted position") {
                    if let state {
                        LabeledContent("Altitude", value: String(format: "%.1f km", state.altitudeKilometers))
                        LabeledContent("Speed", value: String(format: "%.2f km/s", state.speedKilometersPerSecond))
                        LabeledContent("Latitude", value: String(format: "%.2f° %@", abs(state.latitude), state.latitude >= 0 ? "N" : "S"))
                        LabeledContent("Longitude", value: String(format: "%.2f° %@", abs(state.longitude), state.longitude >= 0 ? "E" : "W"))
                        LabeledContent("Position time", value: utc(state.date))
                    } else {
                        Text("A usable position is unavailable. Connect to update orbital data when the next check is available.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let cached {
                    Section("Orbit") {
                        LabeledContent("Orbital period", value: String(format: "%.1f minutes", cached.elements.periodSeconds / 60))
                        LabeledContent("Inclination", value: String(format: "%.2f°", cached.elements.inclination))
                        LabeledContent("Eccentricity", value: String(format: "%.6f", cached.elements.eccentricity))
                        Text("The highlighted loop illustrates the current orbital shape. It is not a forecast of the path over Earth's surface.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Orbital data") {
                        if let epoch = cached.elements.epoch {
                            LabeledContent("Element epoch", value: utc(epoch))
                            LabeledContent("Data age", value: String(format: "%.1f hours", abs(tracking.now.timeIntervalSince(epoch)) / 3600))
                            if OrbitFreshness.assess(epoch: epoch, at: tracking.now) != .fresh {
                                Text("These elements are aging. Predictions may be less accurate; positions disappear after seven days.")
                                    .foregroundStyle(.orange)
                            }
                        }
                        LabeledContent("Downloaded", value: utc(cached.fetchedAt))
                        LabeledContent("Source", value: cached.isBundled ? "Included CelesTrak snapshot" : "CelesTrak download")
                        Text("Positions are calculated with SGP4, not live telemetry. The marker is enlarged for visibility.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Follow satellite", isOn: $isFollowing)
                        .disabled(state == nil || reduceMotion)
                        .accessibilityHint("Keeps this satellite centered as it moves. Dragging or pinching stops following.")
                    if reduceMotion {
                        Text("Follow is unavailable while Reduce Motion is enabled.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("View on globe") { dismiss() }
                    Button("Return to All", systemImage: "globe") {
                        dismiss()
                        returnToAll()
                    }
                }
            }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }
}
