import SwiftUI

struct PlaceSelectionView: View {
    let hasSavedPlace: Bool
    let onSave: (ObserverPlace) -> Void
    let onRemove: () -> Void
    let onPick: () -> Void
    let onViewSky: (ObserverPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String

    init(current: ObserverPlace?, hasSavedPlace: Bool, onSave: @escaping (ObserverPlace) -> Void,
         onRemove: @escaping () -> Void, onPick: @escaping () -> Void, onViewSky: @escaping (ObserverPlace) -> Void) {
        self.hasSavedPlace = hasSavedPlace
        self.onSave = onSave
        self.onRemove = onRemove
        self.onPick = onPick
        self.onViewSky = onViewSky
        _name = State(initialValue: current?.name ?? "")
        _latitude = State(initialValue: current.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: current.map { String($0.longitude) } ?? "")
    }

    private var validPlace: ObserverPlace? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ObserverPlace(name: name, latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Choose on globe", systemImage: "hand.tap") { onPick() }
                    Text("Rotate or zoom the globe, then tap Earth. Taps in this mode choose a place instead of a satellite.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Place coordinates") {
                    TextField("Name", text: $name).onChange(of: name) { _, value in name = String(value.prefix(80)) }
                    TextField("Latitude (−90 to 90)", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude (−180 to 180)", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    Text("Use decimal degrees: north/east are positive, south/west negative. Example: 40.713, −74.006 for New York. Use a period as the decimal separator.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save place", systemImage: "mappin.and.ellipse") {
                        if let place = validPlace { onSave(place); dismiss() }
                    }.disabled(validPlace == nil)
                }
                Section("Sky view") {
                    Button("View sky from here", systemImage: "sparkles") {
                        if let place = validPlace { onViewSky(place) }
                    }.disabled(validPlace == nil)
                    Text("Saves these coordinates and opens a simulated sky showing satellites above the horizon. This does not determine naked-eye visibility.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Your chosen place is saved on this device. No location permission or internet connection is needed. Pass predictions for this place will be added later.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if hasSavedPlace {
                        Button("Remove saved place", role: .destructive) { onRemove(); dismiss() }
                    }
                }
            }
            .navigationTitle("Observer place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
