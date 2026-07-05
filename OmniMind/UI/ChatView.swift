//
//  ChatView.swift
//  OmniMind
//
//  Ask your meeting history anything — a conversation grounded in
//  retrieval, running entirely on-device.
//

import FoundationModels
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
        var sources: [String] = []
    }

    var draft = ""
    private(set) var messages: [Message] = []
    private(set) var thinking = false
    private(set) var unavailable = false

    private var engine: ChatEngine?

    func attach(container: ModelContainer) {
        guard engine == nil else { return }
        engine = ChatEngine(store: EmbeddingStore(modelContainer: container))
        unavailable = SystemLanguageModel.default.availability != .available
    }

    func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !question.isEmpty, !thinking else { return }
        draft = ""
        messages.append(Message(role: .user, text: question))
        thinking = true
        defer { thinking = false }

        if let reply = await engine.ask(question) {
            messages.append(Message(role: .assistant, text: reply.text, sources: reply.sources))
        } else {
            messages.append(Message(
                role: .assistant,
                text: "I couldn't answer that one — try rephrasing, or ask something else."
            ))
        }
    }
}

struct ChatView: View {
    @State private var model = ChatViewModel()
    @Environment(\.modelContext) private var modelContext
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if model.unavailable {
                    ContentUnavailableView(
                        "Needs Apple Intelligence",
                        systemImage: "bubble.left.and.exclamationmark.bubble.right",
                        description: Text("Chatting with your meeting history requires Apple Intelligence on this device.")
                    )
                } else {
                    conversation
                }
            }
            .navigationTitle("Ask Your Meetings")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.attach(container: modelContext.container) }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if model.messages.isEmpty {
                            ContentUnavailableView(
                                "Ask anything",
                                systemImage: "bubble.left.and.text.bubble.right",
                                description: Text("\u{201C}What did we decide about the launch?\u{201D}\n\u{201C}Who owns the budget report?\u{201D}")
                            )
                            .padding(.top, 60)
                        }
                        ForEach(model.messages) { message in
                            bubble(for: message)
                        }
                        if model.thinking {
                            HStack {
                                ProgressView()
                                Text("Reading your meetings…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(.vertical)
                }
                .onChange(of: model.messages) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            inputBar
        }
    }

    private func bubble(for message: ChatViewModel.Message) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(.tint)
                        : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .foregroundStyle(message.role == .user ? .white : .primary)
            if !message.sources.isEmpty {
                Text("From: \(message.sources.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your meetings…", text: Bindable(model).draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { Task { await model.send() } }
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(model.thinking || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding()
        .background(.bar)
    }
}

#Preview {
    ChatView()
        .modelContainer(try! ModelContainerFactory.make(inMemory: true))
}
