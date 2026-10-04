import SwiftUI

struct SatelliteDetailsView: View {
    @ObservedObject var tracking: TrackingStore
    let target: SatelliteTarget
    @Binding var isFollowing: Bool
    let closeSelection: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cached: CachedOrbit? { tracking.results[target]?.cached }
    private var state: OrbitalState? { tracking.frame(for: target)?.state }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let reference = target.referenceImage {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(reference.assetName)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 190)
                            .background(.black, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Reference image of \(target.name)")
                        Text(reference.caption).font(.caption)
                        Link("Image: " + reference.credit, destination: reference.sourceURL)
                            .font(.caption2)
                        if let license = reference.license, let url = URL(string: license) {
                            Link("CC BY 4.0 · image license", destination: url).font(.caption2)
                        }
                        Text("Reference imagery, not a live view.").font(.caption2).foregroundStyle(.secondary)
                    }
                    } else {
                        SatelliteModelIllustration(kind: target.kind)
                            .frame(height: 150)
                        Text("Illustrative satellite model · no spacecraft photo available")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(target.subtitle).font(.headline)
                    LabeledContent("Object type", value: target.kind.name)
                    if target.isStarlink {
                        Text("Starlink constellation member. Launch vehicle and batch are not verified for this entry. Orbit raising and maneuvers can quickly change predictions.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("NORAD catalog ID", value: String(target.id))
                    if let cached { LabeledContent("Catalog name", value: cached.elements.name) }
                }
                Section("Visibility footprint") {
                    Text("The gold area on Earth shows where this satellite is above the horizon for a sea-level observer. Enable it in Settings, then choose View on globe to explore it.")
                    Text("This is geometric line of sight. Darkness, sunlight, brightness, weather, terrain, and atmospheric refraction are not included.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    Button("Back to previous globe view", systemImage: "arrow.uturn.backward") {
                        dismiss()
                        closeSelection()
                    }
                }
            }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                        closeSelection()
                    } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close satellite selection")
                    .accessibilityHint("Returns to your previous globe rotation and zoom.")
                }
            }
        }
        .tint(Color(red: 0.48, green: 0.87, blue: 0.77))
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

/// A clearly labeled schematic for catalog entries without a credited photograph.
struct SatelliteModelIllustration: View {
    let kind: SatelliteKind
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 150, size.height / 90)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            func box(_ rect: CGRect, _ color: Color) { context.fill(Path(rect), with: .color(color)) }
            switch kind {
            case .station:
                box(CGRect(x: -55, y: -3, width: 110, height: 6), .white)
                box(CGRect(x: -7, y: -35, width: 14, height: 70), .white)
                for x in [-48, 25] { for y in [-33, 8] {
                    box(CGRect(x: x, y: y, width: 23, height: 25), .orange)
                } }
            case .satellite:
                box(CGRect(x: -50, y: -14, width: 37, height: 28), .blue)
                box(CGRect(x: 13, y: -14, width: 37, height: 28), .blue)
                box(CGRect(x: -12, y: -12, width: 24, height: 24), .white)
            case .starlink:
                box(CGRect(x: -45, y: -16, width: 30, height: 32), .white)
                box(CGRect(x: -15, y: -16, width: 65, height: 32), .purple)
            }
        }
        .accessibilityLabel("Illustrative \(kind.name) model")
    }
}
