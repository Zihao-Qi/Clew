import ClewAgent
import ClewAI
import SwiftUI

/// Settings › AI (SPEC "Suggest steps"): Continue with ChatGPT, the account, the model,
/// and each job's switch with what it sends.
struct AISettings: View {
    let ai: AIModel
    @State private var editing: NoteDraft?
    @State private var forgetting = false

    var body: some View {
        Group {
            switch ai.phase {
            case .signedOut, .signingIn: signedOut
            case .signedIn: signedIn
            }
            // Under Use AI while ready; in any other state, while any notes are kept (SPEC "Memory").
            if ai.isReady || !ai.memory.notes.isEmpty { notes }
        }
        .sheet(item: $editing) { draft in
            NoteEditor(draft: draft) { about, says in
                if let id = draft.noteId { ai.memory.edit(id, about: about, says: says) } else { ai.memory.add(about: about, says: says) }
                editing = nil
            } cancel: { editing = nil }
        }
        .alert("Forget everything Clew knows?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) { ai.forgetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes Clew's memory and what it has recorded. It can't be undone.")
        }
    }

    private var notes: some View {
        Section {
            if ai.memory.notes.isEmpty {
                Text("Nothing in memory yet. Clew adds to it as it learns how you work, and you can add your own.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ai.memory.shown) { note in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: note.says)
                        Group {
                            if note.from == .you {
                                if note.about.isEmpty { Text("Added by you") } else { Text("\(note.about) · Added by you") }
                            } else if note.confirmed != nil {
                                if note.about.isEmpty { Text("You confirmed") } else { Text("\(note.about) · You confirmed") }
                            } else if note.about.isEmpty {
                                Text(verbatim: note.basedOn ?? "")
                            } else {
                                Text(verbatim: "\(note.about) · \(note.basedOn ?? "")")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { editing = NoteDraft(note) } label: { Image(systemName: "pencil") }
                        .help(Text("Edit"))
                        .accessibilityLabel(Text("Edit memory \(note.says)"))
                    Button { ai.memory.delete(note.id) } label: { Image(systemName: "trash") }
                        .help(Text("Delete"))
                        .accessibilityLabel(Text("Delete memory \(note.says)"))
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Button("Add to memory") { editing = NoteDraft(nil) }
                    .disabled(ai.memory.isFull)
                    .accessibilityLabel(Text("Add to memory"))
                if ai.memory.isFull {
                    Text("Clew keeps up to 40 memories.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget everything") { forgetting = true }
                    .disabled(ai.memory.notes.isEmpty && !ai.isReady)
                    .accessibilityLabel(Text("Forget everything Clew knows"))
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("Clew never changes what you added or edited.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var signedOut: some View {
        Group {
            Section {
                if ai.ended {
                    Text("OpenAI ended Clew's sign-in. Sign in again to use AI.")
                        .foregroundStyle(.secondary)
                }
                if ai.revocationUnconfirmed {
                    Text("Clew couldn't confirm the sign-out with OpenAI. To be sure, disconnect Clew in ChatGPT's settings.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if ai.phase == .signingIn {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { ai.cancelSignIn() }
                            .accessibilityLabel(Text("Cancel signing in"))
                    } else {
                        Button(ai.ended ? "Sign in again" : "Continue with ChatGPT") { ai.signIn() }
                        Spacer()
                    }
                }
                if let message = ai.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Clew can suggest small steps for a task and remember how you work, using your ChatGPT plan. Nothing is sent until you sign in and ask. Clew works fully without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signedIn: some View {
        Group {
            Section {
                LabeledContent {
                    Button("Sign out") { ai.signOut() }
                        .disabled(ai.signingOut)
                        .accessibilityLabel(Text("Sign out of ChatGPT"))
                } label: {
                    Text(verbatim: ai.email ?? String(localized: "Signed in"))
                }
                Link("Manage usage", destination: ChatGPT.usageURL)
                    .accessibilityLabel(Text("Manage ChatGPT usage"))
            } header: {
                Text("ChatGPT")
            }

            if !ai.hasPlanPermission {
                Section {
                    Text("Clew can't use your ChatGPT plan yet.")
                    Button("Continue with ChatGPT") { ai.signIn(consent: true) }
                        .disabled(ai.phase == .signingIn)
                        .accessibilityLabel(Text("Continue with ChatGPT to allow using your plan"))
                }
            } else if ai.notEligible {
                Section {
                    Text("AI isn't available on this ChatGPT plan.").foregroundStyle(.secondary)
                }
            } else {
                if !ai.planNoteSeen {
                    Section {
                        HStack {
                            Text("You're using your ChatGPT plan")
                            Spacer()
                            Button("Got it") { ai.planNoteSeen = true }
                        }
                    }
                }
                Section {
                    LabeledContent {
                        if ai.models.isEmpty {
                            Text("Loading…").foregroundStyle(.secondary)
                        } else {
                            Picker(selection: Binding(get: { ai.model ?? "" }, set: { ai.model = $0 })) {
                                ForEach(ai.models, id: \.slug) { m in Text(verbatim: m.displayName).tag(m.slug) }
                            } label: { EmptyView() }
                                .labelsHidden()
                                .fixedSize()
                                .accessibilityLabel(Text("Model"))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model")
                            Text("Using ChatGPT plan").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { ai.useAI }, set: { ai.useAI = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use AI")
                            Text("Clew suggests steps and remembers how you work, using your ChatGPT plan.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(ai.signingOut)
                    .accessibilityLabel(Text("Use AI"))
                }
            }
            if let message = ai.message {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task { await ai.refreshModels() }
    }
}

/// A note being added (no id) or edited.
struct NoteDraft: Identifiable {
    let id = UUID()
    let noteId: UUID?
    var about: String
    var says: String
    init(_ note: Note?) {
        noteId = note?.id
        about = note?.about ?? ""
        says = note?.says ?? ""
    }
}

/// Edit and Add (SPEC "Memory"): About and Note, capped at 30 and 100 characters.
struct NoteEditor: View {
    @State var draft: NoteDraft
    let save: (String, String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.noteId == nil ? "Add to memory" : "Edit memory").font(.headline)
            Form {
                TextField("About", text: $draft.about, prompt: Text("Writing"))
                    .onChange(of: draft.about) { _, v in if v.count > Memory.aboutLongest { draft.about = String(v.prefix(Memory.aboutLongest)) } }
                    .accessibilityLabel(Text("About"))
                TextField("Memory", text: $draft.says, prompt: Text("Goes better before noon"))
                    .onChange(of: draft.says) { _, v in
                        let line = v.replacingOccurrences(of: "\n", with: " ")
                        if line.count > Memory.saysLongest || line != v { draft.says = String(line.prefix(Memory.saysLongest)) }
                    }
                    .accessibilityLabel(Text("Memory"))
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("Cancel"))
                Button("Save") {
                    save(draft.about.trimmingCharacters(in: .whitespaces), draft.says.trimmingCharacters(in: .whitespaces))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.says.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(Text("Save memory"))
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
