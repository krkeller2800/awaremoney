import SwiftUI
import PDFKit
import Darwin

struct PDFKitView: UIViewRepresentable {
    let url: URL

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
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        let doc: PDFDocument? = withSilencedConsole { PDFDocument(url: url) }
        if let doc { uiView.document = doc }
    }
}
