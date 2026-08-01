@preconcurrency import SwiftTerm
import SwiftUI
import UIKit

struct MobileTerminalView: UIViewRepresentable {
    let controller: MobileSSHController

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.backgroundColor = .black
        view.nativeBackgroundColor = .black
        view.terminalDelegate = context.coordinator
        context.coordinator.terminal = view
        controller.connect { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.controller = controller
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.terminal = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var controller: MobileSSHController
        weak var terminal: TerminalView?

        init(controller: MobileSSHController) {
            self.controller = controller
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            controller.resize(
                cols: newCols,
                rows: newRows,
                pixelWidth: Int(source.bounds.width * source.contentScaleFactor),
                pixelHeight: Int(source.bounds.height * source.contentScaleFactor)
            )
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            controller.title = title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            controller.lastDirectory = directory
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller.send(data)
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let value = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = value
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
