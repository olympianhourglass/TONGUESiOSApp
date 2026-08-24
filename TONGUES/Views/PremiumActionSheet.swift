import SwiftUI
import StoreKit

// Paywall sheet. Layout follows the approved Figma design:
//
//   1. Top hero — motion-blurred bullet-train image behind the TONGUES
//      wordmark (intro-screen treatment: NeueHaas Light, no tracking) with the
//      "A year from now, you'll read things you can't read today."
//      tagline. Top-right glass close button + vertical brand label.
//   2. Tier tab selector (Standard / Pro / Max). Tapping switches the
//      card stack below to that tier's editorial copy + feature rows.
//   3. Black info card — tier headline + 5 icon-led feature rows
//      (words, sentences, languages, audio, model).
//   4. Pricing card — Monthly / Yearly side-by-side panes; the yearly
//      pane carries a dynamic "Save X%" pill computed from the two
//      fallback prices so the math stays accurate when prices change.
//   5. Lime-green CTA button — "Upgrade to {tier.displayName}". Pumps the
//      selected (tier × cycle) into StoreKitClient.purchase.
//   6. Footer — Terms / Privacy / Restore Purchases.
struct PremiumActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    // When set, the sheet is being used as the end-of-onboarding paywall
    // rather than the in-app modal: the top affordance becomes "Skip",
    // and finishing (skip, swipe-down, or a completed purchase) calls this
    // instead of `dismiss()` so onboarding can hand off into the app.
    var onFinish: (() -> Void)? = nil

    @State private var store = StoreKitClient.shared
    @State private var subscription = SubscriptionService.shared
    @State private var selectedTier: SubscriptionTier = .pro
    @State private var selectedCycle: SubscriptionBillingCycle = .monthly
    @State private var isPurchasing: Bool = false
    @State private var purchaseError: String?
    // Drives the in-app promo-code sheet, where the user types a code
    // (e.g. TONGUESVIP). The sheet also exposes Apple's App Store
    // offer-code redemption as a secondary option.
    @State private var showPromoSheet: Bool = false
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
                        // Match the info card's 16pt side margins so the tabs
                        // are exactly as wide as the card beneath them. The
                        // negative top pulls the whole tabs+cards group up 24pt
                        // (was +8), tucking it up against the hero.
                        .padding(.horizontal, 16)
                        .padding(.top, -16)
                    // Info + pricing cards live in a single GlassEffectContainer
                    // so their Liquid Glass actually samples/refracts what's
                    // behind it and reads as real glass rather than a flat dark
                    // fill. spacing: 0 keeps the two pricing panes from merging.
                    GlassEffectContainer(spacing: 0) {
                        // Same 16pt gap between the info card and the pricing
                        // panes as between the tabs and the info card, which
                        // pulls the two pricing rectangles up.
                        VStack(spacing: 16) {
                            infoCard
                            pricingCard
                        }
                    }
                    .padding(.horizontal, 16)
                    // Gap from the tabs down to the cards.
                    .padding(.top, 16)
                    upgradeButton
                        .padding(.horizontal, 16)
                        // Tightened so the CTA rides up into the default frame.
                        .padding(.top, 18)
                    footerLinks
                        .padding(.top, 14)
                        .padding(.bottom, 16)
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
                complete()
            } else if newValue < pullDismissThreshold / 2 {
                didFirePullDismiss = false
            }
        }
        .task {
            await subscription.refresh()
            if store.products.isEmpty {
                await store.loadProducts()
            }
            // In-app (not onboarding): if the user already has a paid tier,
            // open the sheet on their current plan. During onboarding
            // (`onFinish` set) we always land on Pro — the promoted default —
            // regardless of any tier the test/real account already holds.
            if onFinish == nil,
               subscription.currentTier != .free,
               displayTiers.contains(subscription.currentTier) {
                selectedTier = subscription.currentTier
            }
        }
        .alert(
            L("Couldn't start purchase"),
            isPresented: Binding(
                get: { purchaseError != nil },
                set: { if !$0 { purchaseError = nil } }
            ),
            presenting: purchaseError
        ) { _ in
            Button(L("OK")) { purchaseError = nil }
        } message: { error in
            Text(error)
        }
        // In-app promo-code entry. On a successful redemption the sheet
        // dismisses the paywall via onRedeemed so the unlocked app shows.
        .sheet(isPresented: $showPromoSheet) {
            PromoCodeRedeemSheet(onRedeemed: { complete() })
        }
    }

    // MARK: - Hero

    // Tiers that appear in the tab selector. Free is excluded — you
    // don't subscribe to free.
    private let displayTiers: [SubscriptionTier] = [.beginner, .pro, .max]

    // Hero height *below* the safe-area top. The actual rendered
    // height grows by the safe-area inset so the image carries all
    // the way to the very top edge of the sheet without exposing
    // the black underlay. Tall enough to carry the train image down
    // the sheet, but trimmed back so the CTA sits near the default
    // (unscrolled) frame instead of below it.
    private let heroHeight: CGFloat = 300

    private var heroSection: some View {
        ZStack(alignment: .top) {
            stretchyBackground
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                // Wordmark + tagline share the same NeueHaas Light size and
                // hang left off the 16pt margin the cards below use, so the
                // hero copy lines up with the rest of the sheet's content.
                Text("TONGUES")
                    .font(.custom("NeueHaasDisplay-Light", size: 19))
                    .tracking(0)
                    .foregroundStyle(.white)
                Text(L("A year from now, you'll read things you can't read today."))
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Spacer(minLength: 24)
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: heroHeight)
        // The hero floats up under the safe area so the video reaches
        // the very top edge of the sheet. The stretchy background
        // grows downward from that origin on pull-down.
        .ignoresSafeArea(edges: .top)
    }

    // Pull-down-to-stretch effect: the bullet-train hero image grows
    // taller (and slides up by the same amount, keeping its origin
    // anchored) whenever the scroll view is overscrolled past the
    // top edge. The black gradient overlay is applied *inside* the
    // stretching frame so it travels with the image as a single unit
    // — without that, the gradient stayed put while the image pulled
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
                // Motion-blurred bullet-train hero, centered and filling the
                // stretchy header. `colorMultiply(0.7)` knocks the exposure
                // down ~30% so the wordmark/tagline read cleanly over it.
                Image("PaywallHero")
                    .resizable()
                    .scaledToFill()
                    .colorMultiply(Color(white: 0.7))
                LinearGradient(
                    // Pushed down: the image stays clear through the upper
                    // stretch and only hands off to black near the very bottom,
                    // so much more of the train shows before the sheet goes dark
                    // (the bottom black keeps the wordmark/tagline legible).
                    stops: [
                        .init(color: .black.opacity(0.0), location: 0.0),
                        .init(color: .black.opacity(0.0), location: 0.5),
                        .init(color: .black.opacity(0.35), location: 0.82),
                        .init(color: .black, location: 1.0)
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

    // Routes a "done with the paywall" action: onboarding hands off to the
    // app via `onFinish`; the in-app sheet dismisses itself.
    private func complete() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    private var heroTopBar: some View {
        HStack(alignment: .top) {
            Spacer()
            Button {
                Haptics.light()
                complete()
            } label: {
                if onFinish != nil {
                    // Onboarding: a text "Skip" reads as "enter the app for
                    // now" rather than "close this popup".
                    Text(L("Skip"))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
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
                        // Just flip the tier. The highlight capsule's slide is
                        // driven by the `.animation(value:)` on the container
                        // below, which scopes the animation to the tabs so the
                        // info card's text simply blips to the new tier.
                        selectedTier = tier
                    } label: {
                        Text(tier.displayName)
                            .font(.custom("NeueHaasDisplay-Mediu", size: 14))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background {
                                // Only the currently-selected tab
                                // contributes the highlight capsule.
                                // The capsule carries a dark fill +
                                // a black-tinted Liquid Glass pass so
                                // the selected pill reads as a distinctly
                                // darker, raised surface against the
                                // lighter outer glass container — the
                                // earlier light-on-light treatment didn't
                                // have enough contrast to show which tier
                                // was selected. matchedGeometryEffect
                                // interpolates the highlight's frame
                                // between segments instead of fading.
                                if selectedTier == tier {
                                    Capsule()
                                        .fill(Color.black.opacity(0.55))
                                        .glassEffect(
                                            .regular.tint(Color.black.opacity(0.6)),
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
            // design system. NOT `.interactive()`: an interactive glass
            // surface here intercepts touches and swallowed the tab
            // buttons' taps, so `selectedTier` never changed and the CTA
            // kept buying the default (Standard) tier. Tinted ~30% darker so
            // the track reads as a distinctly darker channel behind the pills.
            .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: .capsule)
            // Animate only the tabs (the sliding highlight capsule) on
            // selection — scoped here so the info card beneath just blips to
            // the newly-selected tier's text instead of transitioning.
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: selectedTier)
        }
    }

    // MARK: - Info card (features)

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Chip + headline grouped so the badge reads as a label above the
            // title. The "Popular Plan" chip only shows for the middle (Pro)
            // tier — the same lime/black treatment as the "Save %" chip. Its
            // presence nudges the card taller when Pro is selected; the card is
            // content-sized, so it grows on its own.
            VStack(alignment: .leading, spacing: 12) {
                if selectedTier == .pro {
                    Text(L("Popular Plan"))
                        .font(.custom("NeueHaasDisplay-Roman", size: 10))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.toastBackground))
                }
                Text(selectedTier.headline)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 26))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 4)

            featureRow(
                icon: "text.alignleft",
                value: capValue(selectedTier.monthlyWords),
                suffix: L("Words"),
                unit: L("/month")
            )
            featureRow(
                icon: "text.justify.left",
                value: capValue(selectedTier.monthlySentences),
                suffix: L("Sentences"),
                unit: L("/month")
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
        // Dark Liquid Glass: reads as a raised, glassy surface (soft specular
        // edges over the black sheet) while a heavy black tint keeps it dark
        // enough for the white text to hold high contrast. Sits inside a
        // GlassEffectContainer (see body) so the material renders properly.
        .glassEffect(
            .regular.tint(Color.black.opacity(0.62)),
            in: RoundedRectangle(cornerRadius: 22)
        )
    }

    // "Unlimited" or a thousands-formatted integer string. Used to
    // build the labels in the info card.
    private func capValue(_ value: Int) -> String? {
        if value == Int.max { return nil }
        return value.formatted(.number)
    }

    private var languageSuffix: String {
        if selectedTier.maxLanguages == Int.max { return L("Unlimited Languages") }
        return selectedTier.maxLanguages == 1 ? L("Language Limit") : L("Languages Limit")
    }

    private var audioSuffix: String {
        if selectedTier.monthlyAudioSessions == Int.max { return L("Unlimited Audio") }
        return L("Audio Cap")
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

    // The warm, off-centre glow drawn under whichever pane is selected.
    // Deliberately asymmetric — pushed toward one corner and stretched wide —
    // so it reads as light rather than a uniform halo, and heavily blurred so
    // only a faint warmth survives through the dark glass above it.
    private var selectionGlow: some View {
        RadialGradient(
            colors: [
                Color(red: 1.0, green: 0.58, blue: 0.28).opacity(0.5),
                Color(red: 1.0, green: 0.42, blue: 0.2).opacity(0.0)
            ],
            center: UnitPoint(x: 0.28, y: 0.72),
            startRadius: 0,
            endRadius: 110
        )
        .scaleEffect(x: 1.35, y: 0.7, anchor: UnitPoint(x: 0.28, y: 0.72))
        .blur(radius: 22)
        .opacity(0.55)
        .allowsHitTesting(false)
    }

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
                HStack(spacing: 6) {
                    // Radio-style toggle: a filled check on the active cadence,
                    // a hollow circle on the other — so the slot is always
                    // filled (no awkward gap) and both panes stay balanced.
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.3))
                    Text(L(cycle.label))
                        .font(.custom("NeueHaasDisplay-Light", size: 13))
                        .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
                    Spacer()
                    if cycle == .yearly, let savings = yearlySavingsLabel {
                        Text(savings)
                            .font(.custom("NeueHaasDisplay-Roman", size: 10))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.toastBackground)
                            )
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(mainPriceString(for: cycle))
                        .font(.custom("NeueHaasDisplay-Mediu", size: 22))
                        .foregroundStyle(.white)
                    Text(L("/month"))
                        .font(.custom("NeueHaasDisplay-Light", size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                // Subtle billing-cadence caption. The price above is always
                // the monthly-equivalent; this clarifies the true charge —
                // the full annual amount for yearly, or a plain note for
                // monthly — and keeps both panes the same height.
                Text(billingCaption(for: cycle))
                    .font(.custom("NeueHaasDisplay-Light", size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selection reads through Liquid Glass prominence instead of a
            // border: the active pane sits on lighter (more raised) glass while
            // the other recedes into a darker tint — paired with the lime check
            // in the header. `.interactive()` keeps the live touch response.
            .glassEffect(
                .regular.tint(Color.black.opacity(isSelected ? 0.42 : 0.64)).interactive(),
                in: RoundedRectangle(cornerRadius: 16)
            )
            // A warm bloom sits *behind* the pane and bleeds faintly up through
            // the translucent glass — an extra, subliminal cue for the active
            // cadence. Fades with selection (driven by the same spring).
            .background {
                selectionGlow
                    .opacity(isSelected ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
    }

    // The big number shown on a pricing pane — always the monthly-
    // equivalent so both cadences read in the same "$X / month" format.
    // For yearly this divides the live annual price by 12 (the StoreKit
    // product's own currency format keeps the locale/symbol correct);
    // the fallback yearly value is already stored per-month.
    private func mainPriceString(for cycle: SubscriptionBillingCycle) -> String {
        switch cycle {
        case .monthly:
            return store.product(for: selectedTier, cycle: .monthly)?.displayPrice
                ?? selectedTier.fallbackPrice(for: .monthly)
        case .yearly:
            if let product = store.product(for: selectedTier, cycle: .yearly) {
                return (product.price / 12).formatted(product.priceFormatStyle)
            }
            return selectedTier.fallbackPrice(for: .yearly)
        }
    }

    // The full amount actually charged for the yearly plan (e.g. "$83.88"),
    // used in the subtle "…billed yearly" caption. Prefers the live
    // StoreKit total; the fallback reconstructs it from the per-month value.
    private var annualTotalString: String {
        if let product = store.product(for: selectedTier, cycle: .yearly) {
            return product.displayPrice
        }
        if let perMonth = parsedPrice(selectedTier.fallbackPrice(for: .yearly)) {
            return String(format: "$%.2f", perMonth * 12)
        }
        return ""
    }

    // Subtle line under the price clarifying the real billing cadence.
    private func billingCaption(for cycle: SubscriptionBillingCycle) -> String {
        switch cycle {
        case .monthly: return L("Billed monthly")
        case .yearly:  return L("%@ billed yearly", annualTotalString)
        }
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
        return pct > 0 ? L("Save %d%%", pct) : nil
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
                    complete()
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
                        .font(.custom("NeueHaasDisplay-Roman", size: 16))
                        .foregroundStyle(.black)
                        .opacity(isPurchasing ? 0 : 1)
                    if isPurchasing {
                        ProgressView()
                            .tint(.black)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.toastBackground)
                // Fully rounded in every state (idle, purchasing, disabled).
                .clipShape(Capsule())
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
        if subscription.currentTier == selectedTier { return L("Current Plan") }
        if shouldOfferFreeTrial {
            return L("Start %@ Free Trial", selectedTier.freeTrialLabel)
        }
        return L("Upgrade to %@", selectedTier.displayName)
    }

    private var trialFinePrint: String {
        L("Then %@/month. Cancel anytime.", mainPriceString(for: selectedCycle))
    }

    // MARK: - Footer

    private var footerLinks: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                footerLink(title: L("Terms of Service")) {
                    openURL("https://www.mytongues.com/terms.html")
                }
                footerLink(title: L("Privacy Policy")) {
                    openURL("https://www.mytongues.com/privacy.html")
                }
                footerLink(title: L("Restore Purchases")) {
                    Task { await store.restorePurchases() }
                }
            }
            footerLink(title: L("Redeem Code")) {
                showPromoSheet = true
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
            // Do NOT re-read Firestore here: store.purchase already resolved
            // and applied the new tier to SubscriptionService in memory (and
            // committed it). Re-reading could clobber that with a stale doc
            // if the write lagged/failed, leaving the plan stuck on the old
            // tier. The @Observable state already reflects the upgrade.
            complete()
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
