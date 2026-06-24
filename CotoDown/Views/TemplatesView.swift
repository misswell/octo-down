import SwiftUI

struct TemplatesView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var editedTemplates: [DownloadTemplate] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach($editedTemplates) { $template in
                    Section(sectionTitle(for: template)) {
                        TextField("Name", text: $template.name)
                        Picker("Mode", selection: $template.mode) {
                            ForEach(MediaMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        TextField("yt-dlp arguments", text: $template.arguments, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...5)
                            .font(.system(.footnote, design: .monospaced))

                        Button {
                            duplicate(template)
                        } label: {
                            Label("Duplicate Template", systemImage: "plus.square.on.square")
                        }
                    }
                }
                .onDelete { offsets in
                    editedTemplates.remove(atOffsets: offsets)
                }
                .onMove { offsets, destination in
                    editedTemplates.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .navigationTitle("Templates")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editedTemplates.append(
                            DownloadTemplate(name: "New", mode: .custom, arguments: "")
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add template")
                }

                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Save") {
                            saveTemplates()
                        }
                        Button("Reset Defaults", role: .destructive) {
                            settings.resetTemplates()
                            editedTemplates = settings.templates
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Template actions")
                }
            }
            .onAppear {
                editedTemplates = settings.templates
            }
        }
    }

    private func sectionTitle(for template: DownloadTemplate) -> String {
        let trimmed = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private func duplicate(_ template: DownloadTemplate) {
        var usedNames = Set(editedTemplates.map { $0.name.lowercased() })
        let name = uniqueTemplateName(for: "\(sectionTitle(for: template)) Copy", usedNames: &usedNames)
        let copy = DownloadTemplate(name: name, mode: template.mode, arguments: template.arguments)
        let insertionIndex = (editedTemplates.firstIndex { $0.id == template.id } ?? editedTemplates.endIndex) + 1
        editedTemplates.insert(copy, at: min(insertionIndex, editedTemplates.endIndex))
    }

    private func saveTemplates() {
        let normalizedTemplates = normalizedTemplates(editedTemplates)
        settings.templates = normalizedTemplates.isEmpty ? AppSettings.defaultTemplates : normalizedTemplates
        editedTemplates = settings.templates
    }

    private func normalizedTemplates(_ templates: [DownloadTemplate]) -> [DownloadTemplate] {
        var usedNames = Set<String>()
        return templates.compactMap { template in
            let trimmedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }

            var copy = template
            copy.name = uniqueTemplateName(for: trimmedName, usedNames: &usedNames)
            copy.arguments = template.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
    }

    private func uniqueTemplateName(for name: String, usedNames: inout Set<String>) -> String {
        let baseName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = baseName
        var index = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = "\(baseName) \(index)"
            index += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }
}
