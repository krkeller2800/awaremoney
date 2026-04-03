import SwiftUI
import AVKit
import Combine

#if os(iOS)
import UIKit
#endif

struct HelpVideo: Identifiable, Hashable, Decodable {
    let id: String
    let title: String
    let subtitle: String?
    // Optional per-device URLs and a universal fallback URL
    let iphoneURL: URL?
    let ipadURL: URL?
    let universalURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, url, urls, iphoneURL, ipadURL
    }

    enum URLKeys: String, CodingKey {
        case iphone, ipad
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)

        // Support multiple JSON shapes:
        // 1) legacy: "url": "https://..."
        // 2) recommended: "urls": { "iphone": "...", "ipad": "..." }
        // 3) explicit: "iphoneURL" / "ipadURL"
        universalURL = try container.decodeIfPresent(URL.self, forKey: .url)

        if let urlsContainer = try? container.nestedContainer(keyedBy: URLKeys.self, forKey: .urls) {
            iphoneURL = try urlsContainer.decodeIfPresent(URL.self, forKey: .iphone)
            ipadURL = try urlsContainer.decodeIfPresent(URL.self, forKey: .ipad)
        } else {
            iphoneURL = try container.decodeIfPresent(URL.self, forKey: .iphoneURL)
            ipadURL = try container.decodeIfPresent(URL.self, forKey: .ipadURL)
        }
    }

    // Resolve the best URL for the current device
    var urlForCurrentDevice: URL? {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return ipadURL ?? universalURL ?? iphoneURL
        case .phone:
            return iphoneURL ?? universalURL ?? ipadURL
        default:
            return universalURL ?? ipadURL ?? iphoneURL
        }
        #else
        return universalURL ?? ipadURL ?? iphoneURL
        #endif
    }

    // Whether this video has a playable URL for the current device
    var isAvailableOnCurrentDevice: Bool {
        urlForCurrentDevice != nil
    }
}

@MainActor
final class HelpVideosViewModel: ObservableObject {
    @Published var videos: [HelpVideo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let feedURL = URL(string: "https://komakode.com/videos/help-videos.json")!

    func loadVideos() async {
        isLoading = true
        errorMessage = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: feedURL)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }

            let decoder = JSONDecoder()
            var decoded = try decoder.decode([HelpVideo].self, from: data)
            decoded = decoded.filter { $0.isAvailableOnCurrentDevice }
            videos = decoded
        } catch {
            errorMessage = "Couldn’t load help videos."
            videos = []
            print("Help video load error:", error.localizedDescription)
        }

        isLoading = false
    }
}

struct HelpVideosView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = HelpVideosViewModel()
    @State private var selected: HelpVideo?

    // Player + layout state
    @State private var player: AVPlayer?
    @State private var naturalAspect: CGFloat? = nil
    @State private var sizeObservation: NSKeyValueObservation? = nil
    @State private var isFullScreen: Bool = false
    @State private var isPlaying: Bool = false
    @State private var playObservation: NSKeyValueObservation? = nil

    private var defaultAspect: CGFloat {
        #if os(iOS)
        let size = UIScreen.main.bounds.size
        return size.width / size.height
        #else
        return 16.0 / 9.0
        #endif
    }
    
    private var gridColumns: [GridItem] {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return [GridItem(.flexible(), spacing: 12)]
        } else {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        #else
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.videos.isEmpty {
                    ProgressView("Loading videos...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        Group {
                            if isFullScreen {
                                PlayerViewControllerWrapper(player: player, videoGravity: .resizeAspect)
                                    .aspectRatio(naturalAspect ?? defaultAspect, contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    .background(Color(.white))
                                    .ignoresSafeArea(edges: [.horizontal, .bottom])
                            } else {
                                if selected != nil {
                                    PlayerViewControllerWrapper(player: player, videoGravity: .resizeAspect)
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(naturalAspect ?? defaultAspect, contentMode: .fit)
                                        .background(Color.clear)
                                } else {
                                    ContentUnavailableView(
                                        "No Video Selected",
                                        systemImage: "play.rectangle",
                                        description: Text("Choose a tutorial below.")
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                }
                            }
                        }

                        if !isFullScreen {
                            ScrollView {
                                if let errorMessage = viewModel.errorMessage, viewModel.videos.isEmpty {
                                    ContentUnavailableView(
                                        "Videos Unavailable",
                                        systemImage: "wifi.exclamationmark",
                                        description: Text(errorMessage)
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    .padding()
                                } else if viewModel.videos.isEmpty {
                                    ContentUnavailableView(
                                        "No Videos",
                                        systemImage: "play.rectangle.on.rectangle",
                                        description: Text("No videos available for your device yet.")
                                    )
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    .padding()
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Tutorials")
                                            .font(.headline)
                                            .padding(.horizontal)

                                        LazyVGrid(columns: gridColumns, spacing: 12) {
                                            ForEach(viewModel.videos, id: \.self) { video in
                                                Button {
                                                    selected = video
                                                } label: {
                                                    VStack(alignment: .leading, spacing: 8) {
                                                        HStack(alignment: .top, spacing: 8) {
                                                            Image(systemName: selected?.id == video.id ? "checkmark.circle.fill" : "play.rectangle.fill")
                                                                .font(.title3)
                                                                .foregroundStyle(selected?.id == video.id ? .green : .blue)
                                                            VStack(alignment: .leading, spacing: 4) {
                                                                Text(video.title)
                                                                    .font(.headline)
                                                                    .multilineTextAlignment(.leading)
                                                                    .lineLimit(2)
                                                                if let sub = video.subtitle {
                                                                    Text(sub)
                                                                        .font(.subheadline)
                                                                        .foregroundStyle(.secondary)
                                                                        .lineLimit(2)
                                                                }
                                                            }
                                                            Spacer()
                                                            if selected?.id == video.id {
                                                                Image(systemName: "speaker.wave.2")
                                                                    .foregroundStyle(.tertiary)
                                                            } else {
                                                                Image(systemName: "chevron.right")
                                                                    .foregroundStyle(.tertiary)
                                                            }
                                                        }
                                                    }
                                                    .padding()
                                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal)
                                        .padding(.bottom)
                                    }
                                }
                            }
                            .refreshable {
                                await viewModel.loadVideos()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Help & Tutorials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if isPlaying {
                            player?.pause()
                        } else {
                            player?.play()
                        }
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .disabled(selected == nil || player == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let p = player {
                            p.seek(to: .zero)
                            p.play()
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Restart Video")
                    .disabled(selected == nil || player == nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.snappy) { isFullScreen.toggle() }
                    } label: {
                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
                }
            }
            .task {
                if viewModel.videos.isEmpty {
                    await viewModel.loadVideos()
                }
            }
            .onChange(of: selected) { _, newValue in
                if let vid = newValue {
                    preparePlayer(for: vid)
                } else {
                    player?.pause()
                    player = nil
                    sizeObservation = nil
                    playObservation = nil
                    isPlaying = false
                }
            }
            .onDisappear {
                player?.pause()
                player = nil
                sizeObservation = nil
                playObservation = nil
                isPlaying = false
            }
        }
    }

    private func preparePlayer(for video: HelpVideo) {
        player?.pause()
        // Reset previous observation and state
        playObservation = nil
        isPlaying = false

        guard let resolvedURL = video.urlForCurrentDevice else {
            return
        }
        player = AVPlayer(url: resolvedURL)
        if let item = player?.currentItem {
            sizeObservation = item.observe(\AVPlayerItem.presentationSize, options: [.initial, .new]) { observedItem, _ in
                let size = observedItem.presentationSize
                if size.width > 0 && size.height > 0 {
                    DispatchQueue.main.async { naturalAspect = size.width / size.height }
                }
            }
        }
        // Observe play state to keep toolbar button in sync with native controls
        playObservation = player?.observe(\AVPlayer.timeControlStatus, options: [.initial, .new]) { observedPlayer, _ in
            DispatchQueue.main.async {
                self.isPlaying = (observedPlayer.timeControlStatus == .playing)
            }
        }
        player?.play()
    }

    // MARK: - Player wrappers to control video gravity (fit vs fill)
    private struct PlayerViewControllerWrapper: UIViewControllerRepresentable {
        let player: AVPlayer?
        var videoGravity: AVLayerVideoGravity = .resizeAspect

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let vc = AVPlayerViewController()
            vc.player = player
            vc.videoGravity = videoGravity
            vc.showsPlaybackControls = true
            vc.view.backgroundColor = .clear
            return vc
        }

        func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
            uiViewController.player = player
            uiViewController.videoGravity = videoGravity
            uiViewController.view.backgroundColor = .clear
        }
    }
}

#Preview {
    HelpVideosView()
}
