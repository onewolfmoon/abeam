import SwiftUI
import ProjectorKit

struct ContentView: View {
    @State private var appModel = AppModel()
    @State private var showReceiverSheet = false

    @State private var videoURL: String = ""
    @State private var isSendingVideo = false
    @State private var videoSendError: String?

    @State private var isPlaying = false
    @State private var controlError: String?

    private var hasReceiver: Bool {
        appModel.hasReceiver
    }

    private var statusColor: Color {
        switch appModel.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: Color(.systemGray4)
        }
    }

    private var canSendVideo: Bool {
        !videoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    if hasReceiver {
                        videoURLCard
                        playbackControlsCard
                    } else {
                        emptyReceiverState
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showReceiverSheet) {
            ReceiverPickerSheet(appModel: appModel)
                .presentationDetents([.fraction(0.62), .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Blittie")
                .font(.system(size: 34, weight: .bold))

            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(appModel.receiverName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button(hasReceiver ? "Change" : "Choose") {
                    showReceiverSheet = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.accentColor, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: - Empty state

    private var emptyReceiverState: some View {
        VStack(spacing: 18) {
            Image(systemName: "tv")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Choose a Blittie Screen\nto get started")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Blittie Screen") {
                showReceiverSheet = true
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.accentColor, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Video URL card

    private var videoURLCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VIDEO URL")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            TextField("https://example.com/video.mp4", text: $videoURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                sendVideo()
            } label: {
                HStack {
                    Spacer()
                    if isSendingVideo {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send to TV")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Spacer()
                }
                .padding(.vertical, 13)
            }
            .foregroundStyle(.white)
            .background(canSendVideo ? Color.accentColor : Color(.systemGray4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canSendVideo || isSendingVideo)

            if let videoSendError {
                Text(videoSendError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Playback controls card

    private var playbackControlsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PLAYBACK CONTROLS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)

            HStack(spacing: 30) {
                controlButton(systemImage: "gobackward.15", caption: "15") {
                    sendControl(.seekBack)
                }
                playPauseButton
                controlButton(systemImage: "goforward.15", caption: "15") {
                    sendControl(.seekForward)
                }
                controlButton(systemImage: "stop.fill", caption: "Stop") {
                    isPlaying = false
                    sendStop()
                }
            }
            .frame(maxWidth: .infinity)

            if let controlError {
                Text(controlError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playPauseButton: some View {
        Button {
            isPlaying.toggle()
            sendControl(.playPause)
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
    }

    private func controlButton(systemImage: String, caption: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.65))
                    .frame(width: 50, height: 50)
                    .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text(caption)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func sendVideo() {
        let trimmed = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSendingVideo = true
        videoSendError = nil
        Task {
            defer { isSendingVideo = false }
            do {
                try await appModel.sendYouTube(url: trimmed)
                videoURL = ""
            } catch {
                videoSendError = error.localizedDescription
            }
        }
    }

    private func sendControl(_ control: ReceiverControl) {
        controlError = nil
        Task {
            do {
                try await appModel.sendControl(control)
            } catch {
                controlError = error.localizedDescription
            }
        }
    }

    private func sendStop() {
        controlError = nil
        Task {
            do {
                try await appModel.sendStop()
            } catch {
                controlError = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView()
}
