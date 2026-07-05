import SwiftUI
import StoreKit

// Paywall sheet. Layout follows the approved Figma design:
//
//   1. Top hero — Mouths cardback video behind the TONGUES wordmark
//      with an "Unlock the adventure of a lifetime" tagline. Top-right
//      glass close button + vertical brand label.
//   2. Tier tab selector (Standard / Pro / Max). Tapping switches the
//      card stack below to that tier's editorial copy + feature rows.
//   3. Black info card — tier headline + 5 icon-led feature rows
//      (words, sentences, languages, audio, model).
//   4. Pricing card — Monthly / Yearly side-by-side panes; the yearly
//      pane carries a dynamic "Save X%" pill computed from the two
//      fallback prices so the math stays accurate when prices change.
//   5. Red CTA button — "Upgrade to {tier.displayName}". Pumps the
//      selected (tier × cycle) into StoreKitClient.purchase.
//   6. Footer — Terms / Privacy / Restore Purchases.
struct PremiumActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var store = StoreKitClient.shared
    @State private var subscription = SubscriptionService.shared
    @State private var selectedTier: SubscriptionTier = .beginner
    @State private var selectedCycle: SubscriptionBillingCycle = .monthly
    @State private var isPurchasing: Bool = false
    @State private var purchaseError: String?
    // Tracks how far the user has overscrolled the hero so the body
    // can fire a dismiss once a threshold is crossed.
    @State private var heroPullDistance: CGFloat = 0
    // One-shot guard so the pull-down-to-dismiss only fires once per
    // gesture even though `heroPullDistance` updates many times per
    // frame while the user is pulling.
    @State private var didFirePullDismiss: Bool = false
    private let pullDismissThreshold: CGFloat = 160
    // Namespace shared between the segmented control's selection
    // highlight and each tab's measured frame so the selected glass
    // pill morphs from one tab to the next via matchedGeometryEffect.
    @Namespace private var tabHighlightNamespace

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    // Tier tabs sit between the hero and the info card so
                    // they read as a header for whichever tier's details
                    // appear immediately below — and so the visual jump
                    // from "pick a tier" → "tier details" stays tight.
                    tierTabs
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    infoCard
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    pricingCard
                        .padding(.horizontal, 16)
                        .padding(.top, 28)
                    upgradeButton
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    footerLinks
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)

            // Pinned top bar: X close button stays glued to the sheet's
            // top edge regardless of scroll position — it no longer rides
            // the scroll content, which means it's always reachable.
            heroTopBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .background(Color.black.ignoresSafeArea())
        // Hide the system grabber so the hero image meets the very top
        // edge of the sheet with no gap above it.
        .presentationDragIndicator(.hidden)
        // Extreme swipe-down → dismiss. Sheets normally handle this via
        // the grabber, but with the grabber hidden the gesture lives
        // here so users still have a swipe path out of the paywall.
        .gesture(extremeSwipeDownDismiss)
        // Pull-to-dismiss on the stretchy header: once the user has
        // dragged the hero past `pullDismissThreshold`, fire dismiss
        // exactly once. `didFirePullDismiss` is reset when the pull
        // relaxes back below half the threshold so re-presenting the
        // sheet behaves cleanly.
        .onChange(of: heroPullDistance) { _, newValue in
            if newValue >= pullDismissThreshold, !didFirePullDismiss {
                didFirePullDismiss = true
                Haptics.success()
                dismiss()
            } else if newValue < pullDismissThreshold / 2 {
                didFirePullDismiss = false
            }
        }
        .task {
            await subscription.refresh()
            if store.products.isEmpty {
                await store.loadProducts()
            }
            // If the user already has a paid tier, open the sheet on
            // their current plan rather than the cheapest one.
            if subscription.currentTier != .free,
               displayTiers.contains(subscription.currentTier) {
                selectedTier = subscription.currentTier
            }
        }
        .alert(
            "Couldn't start purchase",
            isPresented: Binding(
                get: { purchaseError != nil },
                set: { if !$0 { purchaseError = nil } }
            ),
            presenting: purchaseError
        ) { _ in
            Button("OK") { purchaseError = nil }
        } message: { error in
            Text(error)
        }
    }

    // MARK: - Hero

    // Tiers that appear in the tab selector. Free is excluded — you
    // don't subscribe to free.
    private let displayTiers: [SubscriptionTier] = [.beginner, .pro, .max]

    // Hero height *below* the safe-area top. The actual rendered
    // height grows by the safe-area inset so the image carries all
    // the way to the very top edge of the sheet without exposing
    // the black underlay.
    private let heroHeight: CGFloat = 280

    private var heroSection: some View {
        ZStack(alignment: .top) {
            stretchyBackground
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TonguesWordmark(size: 44)
                    .foregroundStyle(.white)
                Text("Unlock the adventure of a lifetime")
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                Spacer(minLength: 24)
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .frame(height: heroHeight)
        // The hero floats up under the safe area so the video reaches
        // the very top edge of the sheet. The stretchy background
        // grows downward from that origin on pull-down.
        .ignoresSafeArea(edges: .top)
    }

    // Pull-down-to-stretch effect: the looping Mouths cardback grows
    // taller (and slides up by the same amount, keeping its origin
    // anchored) whenever the scroll view is overscrolled past the
    // top edge. The black gradient overlay is applied *inside* the
    // stretching frame so it travels with the image as a single unit
    // — without that, the gradient stayed put while the video pulled
    // out from under it and a thin black gap would peek through on
    // fast scrolls.
    private var stretchyBackground: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .scrollView(axis: .vertical))
            let pulled = Swift.max(0, frame.minY)
            // Generous top buffer (200pt) so the image is already
            // taller than needed; any inertial overscroll past the
            // GeometryReader's update rate is still covered by the
            // pre-extended canvas instead of revealing the sheet's
            // black underlay.
            let topBuffer: CGFloat = 200
            ZStack {
                CardbackVideoView(resourceName: "Mouths1", isPlaying: true)
                    .scaledToFill()
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.15),
                        Color.black.opacity(0.55),
                        Color.black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height + pulled + topBuffer
            )
            .clipped()
            .offset(y: -pulled - topBuffer)
            // Surface the live pull distance to the body so the
            // dismiss-threshold .onChange there can fire when it
            // crosses the pull-to-dismiss line.
            .onChange(of: pulled) { _, newValue in
                heroPullDistance = newValue
            }
        }
    }

    private var heroTopBar: some View {
        HStack(alignment: .top) {
            Spacer()
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
    }

    private var tierTabs: some View {
        // GlassEffectContainer lets the selected pill's Liquid Glass
        // visually merge with the outer container's glass during the
        // morph between segments — without it the two glasses fight
        // each other through the transition.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(displayTiers, id: \.self) { tier in
                    Button {
                        Haptics.light()
                        // Spring drives the matchedGeometryEffect
                        // slide — the highlight capsule lerps between
                        // tab frames inside this animation block.
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                            selectedTier = tier
                        }
                    } label: {
                        Text(tier.displayName)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background {
                                // Only the currently-selected tab
                                // contributes the highlight capsule.
                                // The capsule carries a light fill +
                                // an explicitly tinted Liquid Glass
                                // pass so the pill reads as a raised
                                // glass surface against the darker
                                // outer container. A fully-clear fill
                                // gave the glass nothing to anchor
                                // to and rendered invisibly.
                                // matchedGeometryEffect interpolates
                                // the highlight's frame between
                                // segments instead of fading in/out.
                                if selectedTier == tier {
                                    Capsule()
                                        .fill(Color.white.opacity(0.08))
                                        .glassEffect(
                                            .regular.tint(Color.white.opacity(0.22)).interactive(),
                                            in: .capsule
                                        )
                                        .matchedGeometryEffect(
                                            id: "tierTabHighlight",
                                            in: tabHighlightNamespace
                                        )
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            // Outer container uses the same Liquid Glass treatment the
            // bottom page toggle on CreateDeckSheet uses, so the
            // paywall segmented control feels native to iOS 26's
            // design system.
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    // MARK: - Info card (features)

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selectedTier.headline)
                .font(.custom("NeueHaasDisplay-Mediu", size: 26))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .padding(.bottom, 4)

            featureRow(
                icon: "text.alignleft",
                value: capValue(selectedTier.monthlyWords),
                suffix: "Words",
                unit: "/month"
            )
            featureRow(
                icon: "text.justify.left",
                value: capValue(selectedTier.monthlySentences),
                suffix: "Sentences",
                unit: "/month"
            )
            featureRow(
                icon: "globe",
                value: capValue(selectedTier.maxLanguages),
                suffix: languageSuffix,
                unit: nil
            )
            featureRow(
                icon: "speaker.wave.2",
                value: capValue(selectedTier.monthlyAudioSessions),
                suffix: audioSuffix,
                unit: nil
            )
            featureRow(
                icon: "sparkles",
                value: nil,
                suffix: selectedTier.generationModelLabel,
                unit: nil
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.08))
        )
    }

    // "Unlimited" or a thousands-formatted integer string. Used to
    // build the labels in the info card.
    private func capValue(_ value: Int) -> String? {
        if value == Int.max { return nil }
        return value.formatted(.number)
    }

    private var languageSuffix: String {
        if selectedTier.maxLanguages == Int.max { return "Unlimited Languages" }
        return selectedTier.maxLanguages == 1 ? "Language Limit" : "Languages Limit"
    }

    private var audioSuffix: String {
        if selectedTier.monthlyAudioSessions == Int.max { return "Unlimited Audio" }
        return "Audio Cap"
    }

    // One feature row: small SF Symbol icon, then either "{value} {suffix}"
    // (e.g. "100 Words") or just "{suffix}" (e.g. "Unlimited Audio").
    // The `unit` is appended in a smaller weight after the suffix to
    // mimic the "/month" treatment in the Figma.
    private func featureRow(
        icon: String,
        value: String?,
        suffix: String,
        unit: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
            HStack(spacing: 4) {
                if let value {
                    Text(value)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                        .foregroundStyle(.white)
                }
                Text(suffix)
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white)
                if let unit {
                    Text(unit)
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .baselineOffset(-1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pricing card (monthly / yearly)

    private var pricingCard: some View {
        HStack(spacing: 10) {
            pricingPane(cycle: .monthly)
            pricingPane(cycle: .yearly)
        }
    }

    private func pricingPane(cycle: SubscriptionBillingCycle) -> some View {
        let isSelected = selectedCycle == cycle
        return Button {
            Haptics.light()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                selectedCycle = cycle
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(cycle.label)
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if cycle == .yearly, let savings = yearlySavingsLabel {
                        Text(savings)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 10))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.red)
                            )
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(displayPrice(for: cycle))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 22))
                        .foregroundStyle(.white)
                    Text("/month")
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected ? Color.white : Color.white.opacity(0.10),
                                lineWidth: isSelected ? 1.2 : 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // Prefer live StoreKit price; fall back to the App Store Connect
    // value baked into SubscriptionTier so the sheet never shows "—".
    private func displayPrice(for cycle: SubscriptionBillingCycle) -> String {
        store.product(for: selectedTier, cycle: cycle)?.displayPrice
            ?? selectedTier.fallbackPrice(for: cycle)
    }

    // Computes "Save 22%" off the monthly-equivalent prices so the
    // pill stays accurate even if Connect prices drift.
    private var yearlySavingsLabel: String? {
        let monthly = parsedPrice(selectedTier.fallbackPrice(for: .monthly))
        let yearly  = parsedPrice(selectedTier.fallbackPrice(for: .yearly))
        guard let monthly, let yearly, monthly > 0, yearly < monthly else {
            return nil
        }
        let savings = 1 - (yearly / monthly)
        let pct = Int((savings * 100).rounded())
        return pct > 0 ? "Save \(pct)%" : nil
    }

    private func parsedPrice(_ text: String) -> Double? {
        // Strip everything but digits and the decimal point so
        // "$8.99" → 8.99. The fallback strings only use ASCII digits +
        // "." so we don't need locale-aware parsing here.
        let filtered = text.filter { $0.isNumber || $0 == "." }
        return Double(filtered)
    }

    // MARK: - Swipe-down-to-dismiss

    // A long, decisive downward swipe closes the sheet. The drag has
    // to clear ~180pt AND end with a positive vertical velocity so
    // taps and tiny scroll jiggles never accidentally dismiss the
    // paywall. Sits at the root ZStack level so it captures gestures
    // outside the ScrollView (the pinned top bar's area, the hero
    // image, etc.).
    private var extremeSwipeDownDismiss: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                let distance = value.translation.height
                let velocity = value.predictedEndTranslation.height - value.translation.height
                if distance > 180 || (distance > 80 && velocity > 200) {
                    Haptics.light()
                    dismiss()
                }
            }
    }

    // MARK: - CTA

    private var upgradeButton: some View {
        VStack(spacing: 8) {
            Button {
                Haptics.medium()
                Task { await purchase() }
            } label: {
                ZStack {
                    Text(ctaLabel)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                        .foregroundStyle(.white)
                        .opacity(isPurchasing ? 0 : 1)
                    if isPurchasing {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing || subscription.currentTier == selectedTier)
            .opacity(subscription.currentTier == selectedTier ? 0.5 : 1)

            // "Then $X/mo. Cancel anytime." subline reinforces the
            // pricing and reassures the user that the free trial
            // doesn't lock them in. Only rendered when we're actively
            // pitching the trial (free → paid). Once the user is on a
            // paid tier the sub-copy disappears.
            if shouldOfferFreeTrial {
                Text(trialFinePrint)
                    .font(.custom("NeueHaasDisplay-Light", size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
    }

    // True when the user is on the free tier — i.e., this is their
    // first time onto a paid tier and StoreKit will honour the
    // introductoryOffer baked into TONGUES.storekit / Connect.
    private var shouldOfferFreeTrial: Bool {
        subscription.currentTier == .free && selectedTier.freeTrialDays > 0
    }

    private var ctaLabel: String {
        if subscription.currentTier == selectedTier { return "Current Plan" }
        if shouldOfferFreeTrial {
            return "Start \(selectedTier.freeTrialLabel) Free Trial"
        }
        return "Upgrade to \(selectedTier.displayName)"
    }

    private var trialFinePrint: String {
        "Then \(displayPrice(for: selectedCycle))/month. Cancel anytime."
    }

    // MARK: - Footer

    private var footerLinks: some View {
        HStack(spacing: 24) {
            footerLink(title: "Terms of Service") {
                openURL("https://www.mytongues.com/terms.html")
            }
            footerLink(title: "Privacy Policy") {
                openURL("https://www.mytongues.com/privacy.html")
            }
            footerLink(title: "Restore Purchases") {
                Task { await store.restorePurchases() }
            }
        }
    }

    private func footerLink(title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(title)
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Purchase

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        let success = await store.purchase(selectedTier, cycle: selectedCycle)
        if success {
            Haptics.success()
            await subscription.refresh()
            dismiss()
        } else if let error = store.lastError {
            // Surface the underlying StoreKit failure so the user
            // isn't left wondering why nothing happened (most often:
            // the App Store Connect product hasn't been created yet
            // OR the local .storekit configuration isn't bound to the
            // run scheme).
            purchaseError = error
        }
    }
}

// Used elsewhere (e.g. older paywall surfaces) to iterate every
// trackable bucket. Kept here since the redesigned sheet doesn't
// surface usage in-line anymore.
extension SubscriptionBucket: CaseIterable {
    public static var allCases: [SubscriptionBucket] {
        [.words, .sentences, .artifacts, .audioSessions]
    }
}
