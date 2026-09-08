import SwiftUI

struct RemotePreviewView: View {
    @Bindable var model: ServerWindowModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Address on server", text: $model.previewAddress).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.preview() } }
                Button("Open") { Task { await model.preview() } }
            }.padding(10)
            Hairline()
            if let browser = model.browser {
                ZStack {
                    BrowserWebView(session: browser).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let failure = browser.failure {
                        EmptyStateView(glyph: "exclamationmark.triangle", title: failure.title,
                            message: failure.message, actionTitle: "Try again", action: { browser.reload() })
                            .background(Palette.surface)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Preview your app", systemImage: "globe", description: Text("Start a development server in the terminal, then enter its localhost address here."))
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
    }
}
