import SwiftUI

struct NewGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String) throws -> AccountGroup
    let onCreated: (AccountGroup) -> Void

    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новая группа")
                .font(.title3.weight(.semibold))

            TextField("Название группы", text: $name)
                .focused($isNameFocused)
                .onSubmit(createGroup)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                Button("Создать", action: createGroup)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isNameFocused = true
        }
        .onChange(of: name) {
            errorMessage = nil
        }
    }

    private func createGroup() {
        do {
            let group = try onCreate(name)
            onCreated(group)
            dismiss()
        } catch AccountStoreError.groupNameRequired {
            errorMessage = "Введите название группы."
        } catch AccountStoreError.duplicateGroupName {
            errorMessage = "Группа с таким названием уже существует."
        } catch {
            errorMessage = "Не удалось создать группу."
        }
    }
}
