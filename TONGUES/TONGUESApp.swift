//
//  TONGUESApp.swift
//  TONGUES
//
//  Created by Albert Yu on 6/1/26.
//

import SwiftUI
import UIKit
import FirebaseCore
import CoreText
import AVFoundation

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// App delegate: registers the app-icon Home Screen quick actions (long-press
// the icon) and installs a scene delegate to deliver taps on them. The
// shortcuts are set dynamically so no Info.plist entry is needed; order here
// is the order shown in the menu, top to bottom: Direct, Conversation,
// Camera.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: "com.tongues.shortcut.direct",
                localizedTitle: "Direct",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "character.bubble")
            ),
            UIApplicationShortcutItem(
                type: "com.tongues.shortcut.conversation",
                localizedTitle: "Conversation",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "bubble.left.and.bubble.right")
            ),
            UIApplicationShortcutItem(
                type: "com.tongues.shortcut.camera",
                localizedTitle: "Camera",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "camera")
            )
        ]
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

// Scene delegate whose only job is delivering app-icon shortcut taps into
// QuickActionRouter. SwiftUI's WindowGroup still owns the window/content;
// we never create one here.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Cold launch from a shortcut: the item arrives in the connection
        // options.
        if let item = connectionOptions.shortcutItem {
            handle(item)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        // Warm launch: app already running when the shortcut is tapped.
        handle(shortcutItem)
        completionHandler(true)
    }

    private func handle(_ item: UIApplicationShortcutItem) {
        guard let action = CreateDeckQuickAction(shortcutType: item.type) else { return }
        Task { @MainActor in
            QuickActionRouter.shared.pending = action
        }
    }
}

// Shared bus between the URL handler in App scope and the navigation
// targets in ContentView + LibraryView. ContentView observes it to
// switch to the Library tab; LibraryView observes it to push the deck
// detail once the decks list is loaded and the matching ID resolves.
@Observable
final class WidgetDeepLinkRouter {
    static let shared = WidgetDeepLinkRouter()
    private init() {}

    var pendingDeckID: String?
}

@main
struct TONGUESApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        FirebaseApp.configure()
        registerCustomFonts()
        configureAudioSessionForStartupChime()
        // Kick off the StoreKit transaction listener + initial
        // entitlement sync. Calling this before any view mounts means
        // a purchase that completes during cold launch (or a renewal
        // that resolved while the app was backgrounded) reaches the
        // subscription mirror before any cap check fires.
        Task { @MainActor in
            StoreKitClient.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.black)  // Drives TextField cursor + system control tints app-wide
                // SwiftUI rendering stays locked to light mode. The
                // status bar style is controlled separately via
                // `AppTabRouter.applyStatusBarStyle`, which flips the
                // window's UIKit `overrideUserInterfaceStyle` per
                // active tab without disturbing this preferredColorScheme.
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    #if canImport(GoogleSignIn)
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    #endif
                    // Widget deep links: tongues://deck/{deckID} opens
                    // the deck the widget's current card belongs to.
                    // ContentView switches to the Library tab and
                    // LibraryView resolves the ID against its loaded
                    // decks to push the DeckDetailView.
                    if url.scheme == "tongues", url.host == "deck" {
                        let deckID = url.pathComponents.dropFirst().first ?? ""
                        guard !deckID.isEmpty else { return }
                        WidgetDeepLinkRouter.shared.pendingDeckID = deckID
                    }
                }
        }
    }
}

// Activate the audio session as early as possible — before the SwiftUI
// splash mounts — so the startup chime's AVAudioPlayer can play through
// reliably on cold launch. Otherwise the session is still warming up when
// the splash's `.task` fires and `player.play()` either no-ops or routes
// nothing audibly, which presents as the chime being "skipped".
private func configureAudioSessionForStartupChime() {
    do {
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try AVAudioSession.sharedInstance().setActive(true)
    } catch {
        print("⚠️ Audio session setup failed at app init: \(error)")
    }
}

private func registerCustomFonts() {
    let names = [
        "PlayfairDisplay-Regular",
        "PlayfairDisplay-Medium",
        "PlayfairDisplay-SemiBold",
        "PlayfairDisplay-Bold",
        "PlayfairDisplay-ExtraBold",
        "PlayfairDisplay-Black",
        "PlayfairDisplay-Italic",
        "PlayfairDisplay-MediumItalic",
        "PlayfairDisplay-SemiBoldItalic",
        "PlayfairDisplay-BoldItalic",
        "PlayfairDisplay-ExtraBoldItalic",
        "PlayfairDisplay-BlackItalic"
    ]
    for name in names {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
            print("⚠️ Missing font file in bundle: \(name).ttf")
            continue
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            let err = error?.takeRetainedValue().localizedDescription ?? "unknown"
            print("⚠️ Font register failed for \(name): \(err)")
        }
    }
}
