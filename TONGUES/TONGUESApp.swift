//
//  TONGUESApp.swift
//  TONGUES
//
//  Created by Albert Yu on 6/1/26.
//

import SwiftUI
import UIKit
import FirebaseCore
import FirebaseAuth
import CoreText
import AVFoundation
import UserNotifications

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// App delegate: registers the app-icon Home Screen quick actions (long-press
// the icon) and installs a scene delegate to deliver taps on them. The
// shortcuts are set dynamically so no Info.plist entry is needed; order here
// is the order shown in the menu, top to bottom: Direct, Conversation,
// Camera.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Receive taps on (and foreground deliveries of) the local streak
        // reminders scheduled by StreakReminderService.
        UNUserNotificationCenter.current().delegate = self

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

    // Hand the APNs device token to Firebase so phone-auth can verify via a
    // silent push. When push isn't available, Firebase falls back to the
    // reCAPTCHA flow (whose callback is handled in `onOpenURL`).
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
    }

    // Let Firebase consume the silent verification push it sends during phone
    // auth. Any other remote notification is a no-op (the app has no other
    // push handling).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        _ = Auth.auth().canHandleNotification(userInfo)
        completionHandler(.noData)
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

    // Show streak reminders even while the app is foregrounded — the user may
    // be on a non-Study tab and still needs the nudge.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Tapping a streak reminder drops the user on the Study tab, where they
    // can start a review right away.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            AppTabRouter.shared.current = .study
        }
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
        // On Mac (Catalyst), hide the window's title bar entirely so the
        // content fills the full window height with only the traffic-light
        // controls floating on top — the smooth, chromeless Messages/Contacts
        // look. `#if targetEnvironment(macCatalyst)` because `titlebar` is a
        // Catalyst-only API.
        #if targetEnvironment(macCatalyst)
        if let windowScene = scene as? UIWindowScene,
           let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .hidden
            titlebar.toolbar = nil
        }
        #endif

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
                    // Firebase phone-auth's reCAPTCHA fallback redirects back
                    // into the app via the reversed-client-id URL scheme. Hand
                    // the URL to Auth first so phone verification can complete;
                    // without this the callback is dropped and sign-in hangs.
                    if Auth.auth().canHandle(url) { return }
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
