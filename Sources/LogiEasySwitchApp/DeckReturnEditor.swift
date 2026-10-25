import SwiftUI

struct DeckReturnEditor: View {
    @Binding var button: DeckButton
    var configuration: DeckConfiguration
    private var rule: DeckReturnBehavior { button.returnAfterAction ?? DeckReturnBehavior() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("Return to", isOn: Binding(get: { rule.enabled }, set: { value in
                    var updated = rule
                    updated.enabled = value
                    button.returnAfterAction = updated
                })).toggleStyle(.checkbox)
                Picker("Return folder", selection: Binding(get: {
                    rule.useParent ? "parent" : rule.folderID?.uuidString ?? "root"
                }, set: { value in
                    var updated = rule
                    updated.useParent = value == "parent"
                    updated.folderID = UUID(uuidString: value)
                    button.returnAfterAction = updated
                })) {
                    Text("Parent folder").tag("parent")
                    Text("Top level").tag("root")
                    ForEach(configuration.buttons.filter { $0.kind == "folder" }) { folder in
                        Text(DeckGroups.folderLabel(folder, configuration: configuration)).tag(folder.id.uuidString)
                    }
                }.labelsHidden().frame(maxWidth: 180).disabled(!rule.enabled)
                TextField("Seconds", value: Binding(get: { rule.delay }, set: { value in
                    var updated = rule
                    updated.delay = value
                    button.returnAfterAction = updated
                }), format: .number).frame(width: 55).disabled(!rule.enabled)
                    .accessibilityLabel("Return delay in seconds")
                Text("seconds after running action").font(.caption)
            }
            Text("Parent folder follows Back. After a successful action, return keeps the window open and overrides auto-dismiss. Another action, navigation, or closing cancels the pending return.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
