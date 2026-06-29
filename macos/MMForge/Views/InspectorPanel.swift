import SwiftUI

/// Right inspector panel for properties, measurements, and tools.
struct InspectorPanel: View {
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tab bar
            Picker("", selection: $selectedTab) {
                Text("Properties").tag(0)
                Text("Measure").tag(1)
                Text("Settings").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case 0:
                    propertiesView
                case 1:
                    measureView
                default:
                    settingsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var propertiesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Properties")
                .font(.headline)
            Text("No selection")
                .foregroundStyle(.secondary)
                .padding(.top, 20)
        }
        .padding(12)
    }

    private var measureView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measurement")
                .font(.headline)
            Text("No measurement active")
                .foregroundStyle(.secondary)
                .padding(.top, 20)
        }
        .padding(12)
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.headline)
            Toggle("Show Grid", isOn: .constant(true))
            Toggle("Show Axes", isOn: .constant(true))
            Toggle("Anti-aliasing", isOn: .constant(true))
        }
        .padding(12)
    }
}
