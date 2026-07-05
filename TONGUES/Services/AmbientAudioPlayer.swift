import Foundation
import AVFoundation

// One selectable background track (an mp3 in the app bundle). `id` is the
// exact resource filename (sans extension); `displayName` is what the
// picker shows.
struct AmbientTrack: Identifiable, Hashable {
    let id: String
    let displayName: String
}

// The two independent ambient channels a listener can layer under their
// study audio. Sound = environmental loops; Music = instrumental beds.
// Filenames must match the assets in TONGUES/Sounds exactly (note the
// intentional "Medival" spelling of the source file).
enum AmbientCatalog {
    static let sounds: [AmbientTrack] = [
        AmbientTrack(id: "Ambient Sound Rain", displayName: "Rain"),
        AmbientTrack(id: "Ambient Sound Ocean", displayName: "Ocean"),
        AmbientTrack(id: "Ambient Sound Forest", displayName: "Forest"),
        AmbientTrack(id: "Ambient Sound Storm", displayName: "Storm"),
        AmbientTrack(id: "Ambient Sound Park", displayName: "Park"),
        AmbientTrack(id: "Ambient Sound Medival Village", displayName: "Medieval Village")
    ]
    static let music: [AmbientTrack] = [
        AmbientTrack(id: "Ambient Music Transcend", displayName: "Transcend"),
        AmbientTrack(id: "Ambient Music Scientific", displayName: "Scientific")
    ]
}

// Plays up to two looping ambient tracks — one "sound" channel and one
// "music" channel — mixed on top of the study session's speech. Each
// channel is independent: setting a channel to a new track swaps it,
// setting it to nil removes it. Kept deliberately quiet so it sits under
// the spoken audio. Because the app's AVAudioSession is already active on
// `.playback` (SpeechClient owns it), these players just mix in alongside
// the speech synthesizer / ElevenLabs playback within the same app.
@MainActor
final class AmbientAudioPlayer {
    enum Channel { case sound, music }

    private var soundPlayer: AVAudioPlayer?
    private var musicPlayer: AVAudioPlayer?

    // Sound sits a touch louder than music since environmental beds are
    // subtler; both stay well under the speech.
    private let soundVolume: Float = 0.35
    private let musicVolume: Float = 0.28

    // Swaps (or clears, when `resource` is nil/empty) the given channel and
    // starts it looping immediately.
    func set(_ resource: String?, for channel: Channel) {
        switch channel {
        case .sound:
            soundPlayer = load(resource, replacing: soundPlayer, volume: soundVolume)
        case .music:
            musicPlayer = load(resource, replacing: musicPlayer, volume: musicVolume)
        }
    }

    private func load(_ resource: String?, replacing existing: AVAudioPlayer?, volume: Float) -> AVAudioPlayer? {
        existing?.stop()
        guard let resource, !resource.isEmpty,
              let url = Bundle.main.url(forResource: resource, withExtension: "mp3") else {
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1   // loop forever
            player.volume = volume
            player.prepareToPlay()
            player.play()
            return player
        } catch {
            print("AmbientAudioPlayer: failed to load \(resource): \(error)")
            return nil
        }
    }

    // Pause/resume both channels in lock-step with the study session's
    // play/pause so the background doesn't keep going while paused.
    func pause() {
        soundPlayer?.pause()
        musicPlayer?.pause()
    }

    func resume() {
        soundPlayer?.play()
        musicPlayer?.play()
    }

    func stopAll() {
        soundPlayer?.stop(); soundPlayer = nil
        musicPlayer?.stop(); musicPlayer = nil
    }
}
