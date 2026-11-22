import ClewAI
import SwiftUI

/// Settings › AI (SPEC "Suggest steps"): Continue with ChatGPT, the account, the model,
/// and each job's switch with what it sends.
struct AISettings: View {
    let ai: AIModel

    var body: some View {
        switch ai.phase {
        case .signedOut, .signingIn: signedOut
        case .signedIn: signedIn
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
                Text("Clew can suggest small steps for a task, using your ChatGPT plan. Nothing is sent until you sign in and ask. Clew works fully without it.")
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
                    Toggle(isOn: Binding(get: { ai.suggestStepsOn }, set: { ai.suggestStepsOn = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggest steps")
                            Text("Sends the task's title, its note and its steps to OpenAI, using your ChatGPT plan.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let message = ai.message {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task { await ai.refreshModels() }
    }
}
