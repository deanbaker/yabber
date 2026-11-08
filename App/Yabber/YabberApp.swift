import SwiftUI

@main
struct YabberApp: App {
    @StateObject private var service = DictationService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
                .onOpenURL { service.handleURL($0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var service: DictationService
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                modelSection
                settingsSection
                setupSection
                historySection
            }
            .navigationTitle("Yabber")
        }
        .overlay {
            if service.openedFromKeyboard && service.status.phase == .recording {
                ListeningOverlay()
            }
        }
    }

    private var sessionSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(service.status.sessionActive ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(service.status.sessionActive ? "Session active" : "Session off")
                    .font(.headline)
                Spacer()
                if service.status.sessionActive, let end = service.sessionEndsAt, service.status.phase != .recording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("ends in \(format(end.timeIntervalSince(context.date)))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if service.status.phase == .recording {
                Label("Recording a dictation", systemImage: "waveform").foregroundStyle(.red)
            } else if service.status.phase == .transcribing {
                Label("Transcribing…", systemImage: "text.bubble")
            }
            if let error = service.lastError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if service.status.sessionActive {
                Button("End session", role: .destructive) { service.endSession("ended in app") }
            } else {
                Button("Start session") { service.startSession() }
            }
        } footer: {
            Text("While a session is active the mic stays on (orange dot) so the keyboard can dictate without opening this app. It turns off after \(Int(service.idleMinutes)) min without a dictation.")
        }
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Parakeet TDT v3", value: service.modelState.label)
            if case .downloading(let fraction) = service.modelState {
                ProgressView(value: fraction)
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Picker("Auto-stop after", selection: $service.idleMinutes) {
                ForEach(DictationService.idleChoices, id: \.self) { Text("\(Int($0)) min").tag($0) }
            }
            Picker("Compute", selection: $service.computePreference) {
                ForEach(ComputePreference.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var setupSection: some View {
        Section("Keyboard setup") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Yabber")
                Text("2. Tap Yabber in that list and turn on Allow Full Access (needed to talk to this app).")
                Text("3. In any text field, hold the globe key and pick Yabber.")
            }
            .font(.callout)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var historySection: some View {
        Section {
            if service.history.isEmpty {
                Text("Dictations appear here, so nothing is lost if insertion fails.")
                    .foregroundStyle(.secondary)
            }
            ForEach(service.history) { item in
                Button {
                    UIPasteboard.general.string = item.text
                    copiedID = item.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).foregroundStyle(.primary)
                        Text("\(item.date.formatted(date: .omitted, time: .shortened)) · \(String(format: "%.1f s audio · %.0f ms · %@", item.audioSeconds, item.latencyMs, item.unit))\(copiedID == item.id ? " · copied" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Recent")
                Spacer()
                if !service.history.isEmpty {
                    Button("Clear") { service.clearHistory() }.font(.caption)
                }
            }
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shown when the keyboard opened the app to start a session.
///
/// Since iOS 26.4 the system no longer shows the "◀ <host app>" breadcrumb for a keyboard-initiated
/// open, and there is no API to send the user back (developer.apple.com/forums/thread/826851).
/// Swiping right along the home indicator always returns to the previous app, so that is the instruction.
private struct ListeningOverlay: View {
    @EnvironmentObject private var service: DictationService

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 64))
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(.red)
            Text("Listening").font(.largeTitle.bold())
            Text("Keep talking. Go back to your app, then tap stop on the keyboard.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            HStack(spacing: 16) {
                Button("Cancel", role: .destructive) { service.handleCancel() }
                    .buttonStyle(.bordered)
                Button("Stop here") { service.handleStop() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            SwipeBackHint()
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// A hand sliding right along a track just above the home indicator, mimicking the swipe-back gesture.
private struct SwipeBackHint: View {
    @State private var travelled = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Swipe right along the bottom edge to go back")
                .font(.headline)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.25)).frame(height: 6)
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .offset(x: travelled ? geo.size.width - 32 : 0, y: 14)
                        .opacity(travelled ? 0.2 : 1)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 180, height: 44)
            Image(systemName: "arrow.down")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                travelled = true
            }
        }
        .accessibilityElement(children: .combine)
    }
}
