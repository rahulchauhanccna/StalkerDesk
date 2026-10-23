//
//  PortalEditorView.swift
//  StalkerDesk
//

import StalkerDeskCore
import SwiftUI

struct PortalEditorView: View {
    let initialDraft: PortalDraft
    var onSaved: ((PortalProfile) -> Void)?

    @EnvironmentObject private var portalStore: PortalStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PortalDraft
    @State private var errorMessage: String?

    init(draft: PortalDraft, onSaved: ((PortalProfile) -> Void)? = nil) {
        self.initialDraft = draft
        self.onSaved = onSaved
        _draft = State(initialValue: draft)
    }

    private var isEditing: Bool {
        portalStore.profiles.contains(where: { $0.id == draft.id })
    }

    private var validationMessage: String? {
        do {
            _ = try draft.validate()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var macIsValid: Bool {
        MACAddress.isValid(draft.macAddress)
    }

    private var hasCredentials: Bool {
        !draft.username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var identityMatchesMAC: Bool {
        guard let mac = MACAddress(draft.macAddress) else { return false }
        return draft.deviceID.caseInsensitiveCompare(DeviceIdentity.defaultDeviceID(for: mac)) == .orderedSame
            && draft.serialNumber.caseInsensitiveCompare(DeviceIdentity.defaultSerial(for: mac)) == .orderedSame
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Portal") {
                    TextField("Name", text: $draft.name, prompt: Text("Living Room Portal"))
                    TextField("Portal URL", text: $draft.portalURL, prompt: Text("http://example.com/c/"))
                        .autocorrectionDisabled()
                }

                Section("Device identity") {
                    TextField(
                        "MAC address",
                        text: Binding(
                            get: { draft.macAddress },
                            set: { newValue in
                                let previousMAC = draft.macAddress
                                draft.macAddress = MACAddress.formatInput(newValue)
                                autoRegenerateIdentityIfNeeded(previousMAC: previousMAC)
                            }
                        ),
                        prompt: Text("00:1A:79:12:34:56")
                    )
                    .font(.system(.body, design: .monospaced))

                    HStack(spacing: 6) {
                        Image(systemName: macIsValid ? (draft.macAddress.hasPrefix(MACAddress.magOUI) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill") : "xmark.octagon.fill")
                            .foregroundStyle(macIsValid ? (draft.macAddress.hasPrefix(MACAddress.magOUI) ? .green : .orange) : .red)
                        Text(macIsValid
                             ? (draft.macAddress.hasPrefix(MACAddress.magOUI)
                                ? "Valid MAG-style MAC address."
                                : "Valid MAC. This portal may expect a 00:1A:79 address.")
                             : "Enter a six-octet MAC address.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        TextField("Device ID", text: $draft.deviceID)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                        Button("Generate") {
                            draft.regenerateIdentity()
                        }
                        .controlSize(.small)
                    }

                    TextField("Serial number", text: $draft.serialNumber)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()

                    if !draft.deviceID.isEmpty, !identityMatchesMAC {
                        Label(
                            "Custom device identity. The portal may reject it if it was generated for a different MAC. Use Generate unless your provider supplied these values.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }

                    Button("Randomize MAC") {
                        let mac = MACAddress.randomMAGAddress()
                        draft.macAddress = mac.formatted
                        draft.regenerateIdentity()
                    }
                    .controlSize(.small)
                }

                Section("Locale") {
                    Picker("Timezone", selection: $draft.timezone) {
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    TextField("Username (optional)", text: $draft.username)
                        .autocorrectionDisabled()
                    SecureField("Password (optional)", text: $draft.password)
                    Text("Credentials are stored in the macOS Keychain and only sent when a username is set. Most MAC-provisioned portals do not require them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasCredentials, draft.portalURL.lowercased().hasPrefix("http://") {
                        Label("This portal uses plain HTTP; credentials will not be encrypted in transit.", systemImage: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Account (optional)")
                }

                Section {
                    Toggle("Use as default portal", isOn: $draft.isDefault)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save Changes" : "Add Portal") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
            .padding(16)
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 560, idealHeight: 640)
        .alert("Could not save portal", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            let saved = try portalStore.save(draft)
            onSaved?(saved)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// If the current identity is simply the MAC-derived default, keep it in
    /// sync when the user edits the MAC. A provider-supplied custom identity is
    /// never overwritten automatically.
    private func autoRegenerateIdentityIfNeeded(previousMAC rawPreviousMAC: String) {
        guard draft.macAddress != rawPreviousMAC else { return }

        if draft.deviceID.isEmpty || draft.serialNumber.isEmpty {
            draft.regenerateIdentity()
            return
        }

        guard let previousMAC = MACAddress(rawPreviousMAC) else {
            draft.regenerateIdentity()
            return
        }

        let previousMatchesDefault =
            draft.deviceID.caseInsensitiveCompare(DeviceIdentity.defaultDeviceID(for: previousMAC)) == .orderedSame
            && draft.serialNumber.caseInsensitiveCompare(DeviceIdentity.defaultSerial(for: previousMAC)) == .orderedSame
        if previousMatchesDefault {
            draft.regenerateIdentity()
        }
    }
}
