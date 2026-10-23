//
//  PortalManagerView.swift
//  StalkerDesk
//

import StalkerDeskCore
import SwiftUI

struct PortalManagerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var portalStore: PortalStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftToEdit: PortalDraft?
    @State private var profileToDelete: PortalProfile?

    var body: some View {
        NavigationStack {
            Group {
                if portalStore.profiles.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No portals yet")
                            .font(.title3.weight(.semibold))
                        Text("Add a Stalker portal URL and the MAC address provisioned by your provider.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Button("Add Portal") {
                            draftToEdit = .newProfile()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(portalStore.profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                isActive: appState.activePortal?.id == profile.id,
                                onConnect: {
                                    appState.connect(to: profile)
                                    dismiss()
                                },
                                onEdit: {
                                    var draft = PortalDraft(
                                        profile: profile,
                                        password: PortalCredentialStore.password(for: profile.id) ?? ""
                                    )
                                    draft.isDefault = profile.isDefault
                                    draftToEdit = draft
                                },
                                onDelete: {
                                    profileToDelete = profile
                                }
                            )
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Portal Manager")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        draftToEdit = .newProfile()
                    } label: {
                        Label("Add Portal", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $draftToEdit) { draft in
                PortalEditorView(draft: draft) { saved in
                    if appState.activePortal?.id == saved.id {
                        appState.portalConfigurationDidChange()
                    }
                }
                .environmentObject(portalStore)
            }
            .alert(
                "Delete Portal?",
                isPresented: Binding(
                    get: { profileToDelete != nil },
                    set: { if !$0 { profileToDelete = nil } }
                ),
                presenting: profileToDelete
            ) { profile in
                Button("Delete", role: .destructive) {
                    if appState.activePortal?.id == profile.id {
                        appState.disconnect()
                    }
                    portalStore.delete(profile)
                    profileToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    profileToDelete = nil
                }
            } message: { profile in
                Text("Remove \(profile.name)? Its saved password and session token will be deleted.")
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 580)
    }
}

private struct ProfileRow: View {
    let profile: PortalProfile
    let isActive: Bool
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var portalStore: PortalStore

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                Image(systemName: isActive ? "dot.radiowaves.left.and.right" : "rectangle.stack")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.headline)
                    if profile.isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if isActive {
                        Text("CONNECTED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(profile.portalURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label(profile.normalizedMAC, systemImage: "network")
                    if let last = profile.lastConnectedAt {
                        Label(last.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(isActive ? "Reconnect" : "Connect", action: onConnect)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Menu {
                Button("Edit…", action: onEdit)
                if !profile.isDefault {
                    Button("Make Default") {
                        portalStore.setDefault(profile)
                    }
                }
                Divider()
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }
}
