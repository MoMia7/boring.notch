//
//  NotchAgentOnboarding.swift
//  boringNotch
//
//  First-run flow for Notch Agent: welcome → permissions → agent → Jev → music source → done.
//

import Defaults
import SwiftUI

struct NotchAgentOnboarding: View {
    enum Step: Int, CaseIterable { case welcome, permissions, agent, jev, music, finish }

    @State private var step: Step
    @Default(.replacedBoringNotch) private var replacedBoringNotch
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    init(initialStep: Step = .welcome, onFinish: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .agent: agent
                case .jev: jev
                case .music:
                    MusicControllerSelectionView(onContinue: {
                        BoringViewCoordinator.shared.firstLaunch = false
                        go(.finish)
                    })
                case .finish: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            if step != .welcome && step != .music {
                HStack(spacing: 6) {
                    ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                        Capsule()
                            .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: s == step ? 18 : 6, height: 6)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(width: 400, height: 600)
        .animation(.easeInOut(duration: 0.35), value: step)
    }

    private func go(_ next: Step) { withAnimation(.easeInOut(duration: 0.35)) { step = next } }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            NotchMarkBadge(mood: .idle)
                .frame(width: 140)
                .padding(.bottom, 8)
            Text("Notch Agent").font(.system(size: 30, weight: .bold))
            Text("An AI agent that lives in your notch.\nHold a key, say what you want, let go.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if replacedBoringNotch {
                Label("Replaced boring.notch. Your settings came along, and everything it did is still here.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Spacer()
            Button("Get started") { go(.permissions) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 40)
        }
    }

    private var permissions: some View {
        stepLayout(title: "Permissions",
                   subtitle: "Notch Agent works best with these. You can change them later in System Settings.",
                   primary: ("Continue", { go(.agent) })) {
            SetupChecklist(groups: [.permissions])
        }
    }

    private var agent: some View {
        stepLayout(title: "The agent",
                   subtitle: "Requests that need thinking go to an AI agent (opencode) running in the background, using ChatGPT, an API key, or a local model.",
                   primary: ("Continue", { go(.jev) })) {
            SetupChecklist(groups: [.agent])
            Text("Run the setup command in Terminal once, then choose a model. Every command the agent wants to run asks for your approval in the notch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var jev: some View {
        stepLayout(title: "Instant actions",
                   subtitle: "Jev is a tiny decision model that routes simple requests (volume, apps, music, reminders, timers, your Shortcuts) straight to an action in about 0.3 s. It costs about a cent a day.",
                   primary: ("Continue", { go(.music) })) {
            JevKeyEntry()
            Link("Get a key at console.typesafe.ai", destination: URL(string: "https://console.typesafe.ai")!)
                .font(.caption)
            Text("Optional. Without a key, everything still works through the agent, just slower.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finish: some View {
        VStack(spacing: 16) {
            Spacer()
            NotchMarkBadge(mood: .listening).frame(width: 110)
            Text("You're set").font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                tip("keyboard", "Hold **right ⌥** and say “volume 50” or “play some Daft Punk”")
                tip("cursorarrow.rays", "Hover the notch for music, calendar and the agent bar")
                tip("command", "Press **⌥ Space** to type to the agent")
            }
            .padding(.horizontal, 36)
            Spacer()
            HStack {
                Button("Open Settings") {
                    BoringViewCoordinator.shared.firstLaunch = false
                    onOpenSettings()
                }
                Button("Done") {
                    BoringViewCoordinator.shared.firstLaunch = false
                    onFinish()
                }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.bottom, 40)
        }
    }

    // MARK: Helpers

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }

    private func stepLayout<Content: View>(title: String, subtitle: String, primary: (String, () -> Void),
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 24, weight: .bold)).padding(.top, 50)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content()
            Spacer()
            HStack {
                Spacer()
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 32)
    }
}

/// Compact Jev key field used in onboarding (Settings has the full section).
struct JevKeyEntry: View {
    @State private var key = ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(DecisionEngine.shared.hasJevKey ? "Key saved · paste to replace" : "Jev API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button(testing ? "Testing…" : "Save & test") {
                    testing = true
                    if !key.isEmpty { JevKeychain.save(key) }
                    key = ""
                    Task {
                        result = await DecisionEngine.shared.testJev()
                        testing = false
                    }
                }
                .disabled(testing || (key.isEmpty && !DecisionEngine.shared.hasJevKey))
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(result.hasPrefix("OK") ? .green : .orange)
            }
        }
    }
}
