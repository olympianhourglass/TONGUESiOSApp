import SwiftUI

// Presented when the user taps the hamburger button in the
// Conversations toolbar. Shows recent threads for the current
// language + a prominent "New chat" row, and lets the user swipe to
// delete or tap to switch threads.
struct ChatHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let language: String
    let isLoading: Bool
    let conversations: [Conversation]
    let currentConversationID: String?
    let onNewChat: () -> Void
    let onOpen: (Conversation) -> Void
    let onDelete: (Conversation) -> Void
    let onRefresh: () async -> Void

    // Holds the chat targeted by either the inline trash button or
    // the swipe action while the user confirms the destructive call.
    @State private var pendingDelete: Conversation?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Haptics.medium()
                        onNewChat()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.black)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New chat")
                                    .font(.custom("NeueHaasDisplay-Mediu", size: 16))
                                    .foregroundStyle(.black)
                                Text("Start a fresh conversation in \(language).")
                                    .font(.custom("NeueHaasDisplay-Light", size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section("Recent") {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                                .font(.custom("NeueHaasDisplay-Light", size: 14))
                                .foregroundStyle(.secondary)
                        }
                    } else if conversations.isEmpty {
                        Text("No saved chats yet.")
                            .font(.custom("NeueHaasDisplay-Light", size: 14))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(conversations) { conversation in
                            Button {
                                Haptics.light()
                                onOpen(conversation)
                            } label: {
                                row(conversation)
                            }
                            .buttonStyle(.plain)
                            // Swipe-left → Delete. `allowsFullSwipe`
                            // lets a confident drag commit without
                            // needing to release on the button —
                            // matches the system Mail / Messages
                            // pattern users expect.
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Haptics.medium()
                                    pendingDelete = conversation
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await onRefresh()
            }
            .navigationTitle("Chat history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .alert(
                "Delete this chat?",
                isPresented: deleteAlertBinding,
                presenting: pendingDelete
            ) { conversation in
                Button("Delete", role: .destructive) {
                    onDelete(conversation)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: { conversation in
                Text("“\(conversation.title)” will be removed from your history. This can't be undone.")
            }
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Subtle "currently open" dot so the user can find the
            // chat they were just looking at when the sheet opens.
            Circle()
                .fill(currentConversationID == conversation.id ? Color.black : Color.clear)
                .frame(width: 6, height: 6)
                .offset(y: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .font(.custom("NeueHaasDisplay-Mediu", size: 15))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Text(conversation.preview)
                    .font(.custom("NeueHaasDisplay-Light", size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // Cross-language history: tag each row with the
                // language so the user can tell at a glance which
                // chat is which.
                Text(conversation.language.uppercased())
                    .font(.custom("NeueHaasDisplay-Mediu", size: 10))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(Color.black.opacity(0.18))
                    )
            }
            Spacer(minLength: 0)
            Text(Self.relativeDate(conversation.updatedAt))
                .font(.custom("NeueHaasDisplay-Light", size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
