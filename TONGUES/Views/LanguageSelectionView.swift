import SwiftUI

// First-run native-language picker. Shown on a black background before the
// splash flips to white and before onboarding, so a user anywhere in the
// world sets the app's language before seeing any English. Selecting a row
// previews that language live (title + button re-localize); Continue commits
// it and lets the launch sequence proceed.
struct LanguageSelectionView: View {
    var onDone: () -> Void = {}

    @State private var selection: AppLanguage = .en

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text(L("Choose your language"))
                    .font(.custom("NeueHaasDisplay-Light", size: 34))
                    .foregroundStyle(.white)
                    .padding(.top, 72)
                    .padding(.horizontal, 24)

                Text(L("This will be your app's language."))
                    .font(.custom("NeueHaasDisplay-Light", size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(AppLanguage.allCases) { lang in
                            languageRow(lang)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                }

                Button {
                    Haptics.medium()
                    withAnimation(.easeOut(duration: 0.35)) {
                        Localizer.shared.choose(selection)
                    }
                    onDone()
                } label: {
                    Text(L("Continue"))
                        .font(.custom("NeueHaasDisplay-Light", size: 20))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        // Preview the selected language's system formatting while choosing.
        .environment(\.locale, Locale(identifier: selection.localeIdentifier))
        .statusBarHidden(true)
    }

    private func languageRow(_ lang: AppLanguage) -> some View {
        let isSelected = selection == lang
        return Button {
            Haptics.light()
            selection = lang
            // Live preview: flip the app language so this screen's own text
            // re-localizes immediately as the user browses.
            Localizer.shared.language = lang
        } label: {
            HStack(spacing: 14) {
                Text(lang.flag)
                    .font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(lang.endonym)
                        .font(.custom("NeueHaasDisplay-Mediu", size: 18))
                        .foregroundStyle(.white)
                    Text(lang.englishName)
                        .font(.custom("NeueHaasDisplay-Light", size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(isSelected ? 0.16 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
