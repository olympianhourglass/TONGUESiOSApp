import SwiftUI

// Shared alert presentation for SubscriptionError.capExceeded. Any
// view that triggers a generation (CreateDeckSheet, GenerateContentSheet,
// PlanView, etc.) attaches `.subscriptionCapAlert($error)` and writes
// the caught error into the binding. The modifier renders an alert with
// an "Upgrade" CTA that opens PremiumActionSheet in place.
struct SubscriptionCapAlertModifier: ViewModifier {
    @Binding var error: SubscriptionError?
    @State private var showPaywall = false

    func body(content: Content) -> some View {
        content
            .alert(
                "You've hit your monthly limit",
                isPresented: alertBinding,
                presenting: error
            ) { _ in
                Button("Upgrade") {
                    showPaywall = true
                    error = nil
                }
                Button("Not now", role: .cancel) {
                    error = nil
                }
            } message: { error in
                Text(error.errorDescription ?? "")
            }
            .sheet(isPresented: $showPaywall) {
                PremiumActionSheet()
            }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )
    }
}

extension View {
    func subscriptionCapAlert(_ error: Binding<SubscriptionError?>) -> some View {
        modifier(SubscriptionCapAlertModifier(error: error))
    }
}
