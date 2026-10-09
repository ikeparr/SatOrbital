import SwiftUI

struct ObserverSkyView: View {
    @ObservedObject var tracking: TrackingStore
    let place: ObserverPlace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pose = SkyViewPose()
    @State private var dragOrigin: SkyViewPose?
    @State private var detailsTarget: SatelliteTarget?
    @State private var showsSatelliteSheet = false

    private struct Entry: Identifiable {
        let target: SatelliteTarget
        let observation: SkyObservation
        var id: Int { target.id }
    }

    private func entries(at date: Date) -> [Entry] {
        tracking.frames.compactMap { target, frame in
            guard let observation = SkyObservation(place: place, satellite: frame.skyEarthFixedPosition(at: date)),
                  observation.isAboveHorizon else { return nil }
            return Entry(target: target, observation: observation)
        }.sorted { $0.observation.rangeKilometers > $1.observation.rangeKilometers }
    }

    private func color(for target: SatelliteTarget) -> Color {
        switch target.kind {
        case .station: .orange
        case .starlink: .purple
        case .satellite: .cyan
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sky from " + place.name).font(.headline).lineLimit(2)
                    Text(place.coordinates).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    .frame(width: 44, height: 44).accessibilityLabel("Return to globe")
            }.padding(.horizontal)
            VStack(spacing: 4) {
                Text(tracking.displayDate.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit())
                Text(String(format: "Looking %.0f° from north · %.0f° up", normalizedHeading, pose.elevation))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 15,
                                    paused: !tracking.isLive || scenePhase != .active || reduceMotion)) { timeline in
                sky(entries: entries(at: timeline.date))
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 8)
            HStack(spacing: 8) {
                ForEach([("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)], id: \.0) { label, heading in
                    Button(label) { pose.heading = heading }
                        .frame(minWidth: 40, minHeight: 44)
                        .accessibilityLabel("Look " + ["N": "north", "E": "east", "S": "south", "W": "west"][label]!)
                }
                Spacer(minLength: 0)
                Button { pose.elevation = min(85, pose.elevation + 20) } label: { Image(systemName: "arrow.up") }
                    .frame(width: 44, height: 44).accessibilityLabel("Look higher")
                Button { pose.elevation = max(-10, pose.elevation - 20) } label: { Image(systemName: "arrow.down") }
                    .frame(width: 44, height: 44).accessibilityLabel("Look lower")
            }.padding(.horizontal)
            HStack {
                Button("Above horizon", systemImage: "list.bullet") { detailsTarget = nil; showsSatelliteSheet = true }
                Spacer()
                Menu {
                    Picker("Playback speed", selection: Binding(get: { tracking.playbackRate }, set: { rate in
                        Task { await tracking.setPlaybackRate(rate) }
                    })) {
                        Text("1×").tag(1.0); Text("10×").tag(10.0); Text("60×").tag(60.0)
                    }
                    Button("15 minutes earlier") { Task { await tracking.seek(to: tracking.displayDate.addingTimeInterval(-900)) } }
                    Button("15 minutes later") { Task { await tracking.seek(to: tracking.displayDate.addingTimeInterval(900)) } }
                } label: { Label("Time · \(Int(tracking.playbackRate))×", systemImage: "clock") }
                Button { Task { await tracking.togglePlayback() } } label: {
                    Image(systemName: tracking.isLive ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(tracking.isLive ? "Pause sky playback" : "Play sky playback")
                Button("NOW") { Task { await tracking.returnToNow() } }.frame(minHeight: 44)
            }.font(.caption).padding(.horizontal)
            if let notice = tracking.notice ?? tracking.predictionError {
                Text(notice).font(.caption2).foregroundStyle(.orange).lineLimit(2).padding(.horizontal)
            }
            Text("Predicted directions · current satellite filters apply\nAbove the horizon does not mean visible to the naked eye.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal).padding(.bottom, 8)
        }
        .background(Color(red: 0.018, green: 0.030, blue: 0.055).ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(Color(red: 0.48, green: 0.87, blue: 0.77))
        .sheet(isPresented: $showsSatelliteSheet, onDismiss: { detailsTarget = nil }) {
            if let target = detailsTarget {
                SatelliteDetailsView(tracking: tracking, target: target, isFollowing: .constant(false),
                                     closeSelection: { showsSatelliteSheet = false }, observerPlace: place)
            } else { aboveHorizonList }
        }
    }

    private var normalizedHeading: Double { (pose.heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }

    private func sky(entries: [Entry]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let aspect = Double(size.width / max(size.height, 1))
            ZStack {
                LinearGradient(colors: [Color(red: 0.025, green: 0.045, blue: 0.11), Color(red: 0.06, green: 0.12, blue: 0.19)], startPoint: .top, endPoint: .bottom)
                Canvas { context, canvasSize in
                    let horizon = CGFloat(pose.horizonY) * canvasSize.height
                    if horizon < canvasSize.height {
                        let top = max(0, horizon)
                        context.fill(Path(CGRect(x: 0, y: top, width: canvasSize.width, height: canvasSize.height - top)),
                                     with: .color(Color(red: 0.04, green: 0.09, blue: 0.075)))
                    }
                    if horizon >= 0 && horizon <= canvasSize.height {
                        var line = Path(); line.move(to: CGPoint(x: 0, y: horizon)); line.addLine(to: CGPoint(x: canvasSize.width, y: horizon))
                        context.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
                        context.draw(Text("HORIZON · 0°").font(.caption2).foregroundStyle(.white.opacity(0.6)),
                                     at: CGPoint(x: 8, y: horizon + 10), anchor: .topLeading)
                    }
                    for elevation in [30.0, 60.0] {
                        var curve = Path(); var drawing = false
                        for offset in stride(from: -85.0, through: 85.0, by: 2) {
                            if let point = pose.project(SkyViewPose.direction(azimuth: pose.heading + offset, elevation: elevation), aspect: aspect),
                               abs(point.x) < 5, abs(point.y) < 5 {
                                let p = CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
                                if drawing { curve.addLine(to: p) } else { curve.move(to: p); drawing = true }
                            } else { drawing = false }
                        }
                        context.stroke(curve, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
                        if let p = pose.project(SkyViewPose.direction(azimuth: pose.heading, elevation: elevation), aspect: aspect) {
                            context.draw(Text("\(Int(elevation))°").font(.caption2).foregroundStyle(.white.opacity(0.4)),
                                         at: CGPoint(x: canvasSize.width / 2, y: p.y * canvasSize.height - 9))
                        }
                    }
                    for (label, azimuth) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                        if let p = pose.project(SkyViewPose.direction(azimuth: azimuth, elevation: 0), aspect: aspect) {
                            context.draw(Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7)),
                                         at: CGPoint(x: p.x * canvasSize.width, y: p.y * canvasSize.height - 16))
                        }
                    }
                }.allowsHitTesting(false)
                ForEach(entries) { entry in
                    if let p = pose.project(entry.observation.direction, aspect: aspect),
                       (0...1).contains(p.x), (0...1).contains(p.y) {
                        Button {
                            detailsTarget = entry.target
                            showsSatelliteSheet = true
                        } label: {
                            Image(systemName: entry.target.kind == .station ? "sparkle" : entry.target.kind == .starlink ? "circle.fill" : "diamond.fill")
                                .font(.system(size: entry.target.kind == .station ? 14 : 8))
                                .foregroundStyle(color(for: entry.target))
                                .frame(width: 44, height: 44).contentShape(Circle())
                        }
                        .accessibilityLabel(entry.target.name)
                        .accessibilityValue(String(format: "Direction %.0f degrees, elevation %.0f degrees", entry.observation.azimuthDegrees, entry.observation.elevationDegrees))
                        .position(x: p.x * size.width, y: p.y * size.height)
                    }
                }
                if entries.isEmpty {
                    Text(tracking.frames.isEmpty ? "No usable satellite positions in the current filters." : "No tracked satellites are above this place’s horizon at this time.")
                        .font(.subheadline).multilineTextAlignment(.center).padding(24).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                if dragOrigin == nil { dragOrigin = pose }
                guard let start = dragOrigin else { return }
                pose.heading = start.heading - Double(value.translation.width) * 0.25
                pose.elevation = min(max(start.elevation + Double(value.translation.height) * 0.18, -10), 85)
            }.onEnded { _ in dragOrigin = nil })
            .clipped()
        }
    }

    private var aboveHorizonList: some View {
        NavigationStack {
            List {
                let visible = entries(at: Date()).sorted { $0.observation.elevationDegrees > $1.observation.elevationDegrees }
                if visible.isEmpty { Text("No tracked satellites above the horizon in the current filters.") }
                ForEach(visible) { entry in
                    Button {
                        pose.heading = entry.observation.azimuthDegrees
                        pose.elevation = min(85, max(0, entry.observation.elevationDegrees))
                        detailsTarget = entry.target
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.target.name).foregroundStyle(color(for: entry.target))
                            Text(String(format: "Direction %.1f° · elevation %.1f° · %.0f km away", entry.observation.azimuthDegrees, entry.observation.elevationDegrees, entry.observation.rangeKilometers))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Above horizon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSatelliteSheet = false } } }
        }
    }
}
