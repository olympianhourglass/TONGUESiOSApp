import SwiftUI
import AVFoundation
import UIKit

// AVPlayerLayer-backed view used for video-style deck cardbacks. Renders
// without playback controls and is muted because the cardbacks are decorative.
//
// IMPORTANT: this view only exists while a video is actively playing.
// Off-state cards show `CardbackThumbnailCache.image(for:)` as a static
// poster — see `DeckCoverFill`. Mounting an `AVPlayer` per visible mini-card
// previously caused jetsam SIGKILLs on the Study page when several
// video-style decks were on screen at once.
struct CardbackVideoView: UIViewRepresentable {
    let resourceName: String
    let isPlaying: Bool

    func makeUIView(context: Context) -> CardbackPlayerView {
        let view = CardbackPlayerView()
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
            return view
        }
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.seek(to: .zero)
        if isPlaying { player.play() }
        return view
    }

    func updateUIView(_ view: CardbackPlayerView, context: Context) {
        guard let player = view.playerLayer.player else { return }
        if isPlaying {
            if let item = player.currentItem,
               player.currentTime() >= item.duration, item.duration.isValid {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
            player.seek(to: .zero)
        }
    }
}

final class CardbackPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Default UIView + AVPlayerLayer backgrounds render opaque black
        // until the first frame is decoded, which causes a one-frame flash
        // when the video mounts. Clearing both lets the poster image stacked
        // beneath this view show through that load window seamlessly.
        backgroundColor = .clear
        isOpaque = false
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.isOpaque = false
    }
}

// Process-wide cache of first-frame thumbnails for video cardbacks. Each
// cardback's frame is extracted once via AVAssetImageGenerator and reused
// as the static poster in every deck sharing that style — so we never need
// to keep `AVPlayer`s alive just to render a still image.
@MainActor
enum CardbackThumbnailCache {
    private static var cache: [String: UIImage] = [:]
    private static var inFlight: Set<String> = []

    static func image(for resourceName: String) -> UIImage? {
        cache[resourceName]
    }

    static func prepare(for resourceName: String) async {
        if cache[resourceName] != nil { return }
        if inFlight.contains(resourceName) { return }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else { return }
        inFlight.insert(resourceName)
        defer { inFlight.remove(resourceName) }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 320)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            cache[resourceName] = UIImage(cgImage: cgImage)
        } catch {
            // Fall through — DeckCoverFill will render the solid backing color.
        }
    }
}
