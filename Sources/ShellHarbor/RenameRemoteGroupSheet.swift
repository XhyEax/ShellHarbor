import SwiftUI

struct RenameRemoteGroupSheet: View {
    let currentName: String
    let existingGroupNames: [String]
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var nameIsFocused: Bool

    init(
        currentName: String,
        existingGroupNames: [String],
        onRename: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentName = currentName
        self.existingGroupNames = existingGroupNames
        self.onRename = onRename
        self.onCancel = onCancel
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名分组")
                .font(.headline)

            TextField("分组名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit(rename)

            if isDuplicate {
                Text("已存在同名分组。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("重命名", action: rename)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        normalizedName == nil ||
                            isDuplicate ||
                            isUnchanged
                    )
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            nameIsFocused = true
        }
    }

    private var normalizedName: String? {
        RemoteGroupName.normalized(name)
    }

    private var isDuplicate: Bool {
        guard let normalizedName else { return false }
        return existingGroupNames.contains {
            $0.caseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    private var isUnchanged: Bool {
        normalizedName?.caseInsensitiveCompare(currentName) == .orderedSame
    }

    private func rename() {
        guard
            let normalizedName,
            !isDuplicate,
            !isUnchanged
        else {
            return
        }
        onRename(normalizedName)
    }
}
