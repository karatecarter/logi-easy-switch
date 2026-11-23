import SwiftUI
import UniformTypeIdentifiers

struct DestinationActionEditor: View {
    let title: String
    @Binding var action: DestinationSwitchAction
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("Action", selection: $action.kind) {
                        ForEach(DestinationSwitchAction.Kind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }.labelsHidden().frame(width: 165)
                }
                if action.kind == .command {
                    TextField("Shell command (optional)", text: $action.command, axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                } else if action.kind == .application {
                    HStack {
                        TextField("Application path (optional)", text: $action.applicationPath)
                        Button("Choose…") { chooseApplication() }
                    }
                }
            }.padding(4)
        }
    }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application to open after switching"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url { action.applicationPath = url.path }
        }
    }
}
