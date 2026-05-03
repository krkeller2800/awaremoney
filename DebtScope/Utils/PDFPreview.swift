import SwiftUI

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(UIKit)
import UIKit
#endif

struct PDFPreview: View {
    let url: URL

    var body: some View {
#if canImport(PDFKit)
        if isSafeReadablePDF(url) {
            PDFKitRepresentedView(url: url)
        } else {
            ContentUnavailableView(
                "Cannot display PDF",
                systemImage: "xmark.circle.fill",
                description: Text("The file is not a readable PDF document.")
            )
        }
#else
        ContentUnavailableView(
            "PDFKit unsupported",
            systemImage: "xmark.circle.fill",
            description: Text("PDF preview is not supported on this platform.")
        )
#endif
    }

    private func isSafeReadablePDF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true else { return false }
            guard let fileSize = resourceValues.fileSize, fileSize > 0 else { return false }
        } catch {
            return false
        }
        return true
    }
}

#if canImport(PDFKit)

struct PDFKitRepresentedView: View {
    let url: URL

    var body: some View {
#if canImport(UIKit)
        PDFKitUIView(url: url)
#else
        PDFKitNSView(url: url)
#endif
    }
}

#if canImport(UIKit)
private struct PDFKitUIView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysAsBook = false
        pdfView.backgroundColor = .clear
        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
#else
import AppKit

private struct PDFKitNSView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysAsBook = false
        pdfView.backgroundColor = .clear
        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
#endif

#endif

