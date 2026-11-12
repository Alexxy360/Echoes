import Foundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class MusicService {
    private(set) var isEnabled = false
    private(set) var title = ""
    private(set) var songID = ""
    private(set) var authorization = MPMediaLibrary.authorizationStatus()
    private var observing = false

    func enable() async {
        authorization = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            disable()
            return
        }
        isEnabled = true
        if !observing {
            let player = MPMusicPlayerController.systemMusicPlayer
            NotificationCenter.default.addObserver(
                self, selector: #selector(playerChanged),
                name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
            NotificationCenter.default.addObserver(
                self, selector: #selector(playerChanged),
                name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
            player.beginGeneratingPlaybackNotifications()
            observing = true
        }
        refresh()
    }

    func disable() {
        if observing { MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications() }
        NotificationCenter.default.removeObserver(self)
        observing = false
        isEnabled = false
        title = ""
        songID = ""
    }

    @objc private func playerChanged(_ notification: Notification) { refresh() }

    func refresh() {
        guard isEnabled else { return }
        authorization = MPMediaLibrary.authorizationStatus()
        guard authorization == .authorized else {
            disable()
            return
        }
        let player = MPMusicPlayerController.systemMusicPlayer
        guard player.playbackState == .playing, let item = player.nowPlayingItem,
            let name = item.title, !name.isEmpty
        else {
            title = ""
            songID = ""
            return
        }
        let fullTitle = item.artist.map { name + " — " + $0 } ?? name
        var displayTitle = ""
        var length = 0
        for character in fullTitle.prefix(300) {
            let units = String(character).utf16.count
            guard length + units <= 300 else { break }
            displayTitle.append(character)
            length += units
        }
        title = displayTitle
        let id = item.playbackStoreID
        songID = id.utf8.allSatisfy { (48...57).contains($0) } && id.utf8.count <= 30 ? id : ""
    }
}
