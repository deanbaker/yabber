import SwiftUI

@main
struct ProbeApp: App {
    @StateObject private var probe = Probe()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(probe)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var probe: Probe

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Setup") {
                        Picker("Compute", selection: $probe.mode) {
                            ForEach(ComputeMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Background run", selection: $probe.plan) {
                            ForEach(BackgroundPlan.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Reload models in background", isOn: $probe.reloadInBackground)
                        Toggle("Mic stop/restart test", isOn: $probe.micRestartTest)
                    }
                    .disabled(probe.running)

                    Section {
                        if probe.running {
                            Button("Cancel", role: .destructive) { probe.cancel() }
                        } else {
                            Button("Run test") { probe.start() }.bold()
                        }
                        Text(probe.status).font(.callout)
                        if let url = probe.logURL, !probe.running {
                            ShareLink("Share log", item: url)
                        }
                    }
                }
                .frame(height: 360)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(probe.lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: probe.lines.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("BG Probe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
