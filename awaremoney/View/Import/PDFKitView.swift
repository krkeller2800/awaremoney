import SwiftUI
import PDFKit
import Darwin

struct PDFKitView: UIViewRepresentable {
    let url: URL

    class Coordinator {
        var lastURL: URL?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    // Silences stdout/stderr temporarily to suppress noisy PDFKit/CoreGraphics console logs
    private func withSilencedConsole<T>(_ body: () throws -> T) rethrows -> T {
        fflush(stdout)
        fflush(stderr)
        let devNull = open("/dev/null", O_WRONLY)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        if devNull != -1 {
            dup2(devNull, STDOUT_FILENO)
            dup2(devNull, STDERR_FILENO)
            close(devNull)
        }
        defer {
            fflush(stdout)
            fflush(stderr)
            if savedOut != -1 { dup2(savedOut, STDOUT_FILENO); close(savedOut) }
            if savedErr != -1 { dup2(savedErr, STDERR_FILENO); close(savedErr) }
        }
        return try body()
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        let doc: PDFDocument? = withSilencedConsole { PDFDocument(url: url) }
        if let doc { pdfView.document = doc }
        context.coordinator.lastURL = url
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only reload if the URL actually changed to avoid redundant work
        guard context.coordinator.lastURL != url else { return }
        let doc: PDFDocument? = withSilencedConsole { PDFDocument(url: url) }
        uiView.document = doc
        context.coordinator.lastURL = url
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        // Explicitly release the document to ensure file handles and observers are torn down
        uiView.document = nil
        coordinator.lastURL = nil
    }
}
