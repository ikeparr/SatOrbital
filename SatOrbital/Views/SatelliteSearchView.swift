import SwiftUI

struct SatelliteSearchView: View {
    let selected: SatelliteTarget?
    let onSelect: (SatelliteTarget?) -> Void
    @State private var query = ""
    @State private var starlinkOnly = false
    @Environment(\.dismiss) private var dismiss

    private var matches: [SatelliteTarget] {
        SatelliteTarget.matching(query).filter { !starlinkOnly || $0.isStarlink }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { onSelect(nil) } label: {
                        Label("All satellites · Earth overview", systemImage: "globe")
                            .foregroundStyle(.primary)
                    }
                }
                Section {
                    Toggle("Starlink only", isOn: $starlinkOnly)
                }
                Section("Included satellites") {
                    ForEach(matches) { target in
                        Button { onSelect(target) } label: {
                            HStack(spacing: 12) {
                                Group {
                                if let reference = target.referenceImage {
                                Image(reference.assetName)
                                    .resizable().scaledToFit()
                                    .frame(width: 64, height: 52)
                                    .background(.black, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityHidden(true)
                                } else {
                                    SatelliteModelIllustration(kind: target.kind).frame(width: 64, height: 52).accessibilityHidden(true)
                                }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.name).font(.headline)
                                    Text(target.subtitle).font(.caption).foregroundStyle(.secondary)
                                    Text("NORAD \(String(target.id))").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if selected == target { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("\(target.name), \(target.subtitle), NORAD \(String(target.id))")
                    }
                    if matches.isEmpty {
                        Text("No matching satellites. Try a name, NORAD ID, or alias such as HST or JPSS-1.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Search the \(SatelliteTarget.allCases.count) satellites currently included. Tap a result to focus the globe and see details.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or NORAD ID")
            .navigationTitle("Find a satellite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(Color(red: 0.48, green: 0.87, blue: 0.77))
    }
}
