import SwiftUI

struct NewRemoteGroupSheet: View {
    let existingGroupNames: [String]
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建分组")
                .font(.headline)

            TextField("分组名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit(create)

            if isDuplicate {
                Text("已存在同名分组。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedName == nil || isDuplicate)
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

    private func create() {
        guard let normalizedName, !isDuplicate else { return }
        onCreate(normalizedName)
    }
}
