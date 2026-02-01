import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let appIconName = "AppIcon"
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown App"

    private var versionBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    private var compileDate: String {
        #if DEBUG
        let compileDateString = "2026-01-31T12:00:00Z" // Replace with actual compile date or keep fixed for preview
        #else
        let compileDateString = "\(Date())"
        #endif
        let formatterInput = ISO8601DateFormatter()
        let formatterOutput = DateFormatter()
        formatterOutput.dateStyle = .medium
        formatterOutput.timeStyle = .none

        if let date = formatterInput.date(from: compileDateString) {
            return "Compiled on \(formatterOutput.string(from: date))"
        }
        return "Compiled on unknown date"
    }

    private let supportURL = URL(string: "mailto:support@komakode.com?subject=Aware%20Money%20support")!
    private let privacyPolicyURL = URL(string: "https://komakode.com/Privacy%20Policy")!
    private let acknowledgementsURL = URL(string: "https://acknowledgements.example.com")!

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(uiImage: UIImage(named: "aware") ?? UIImage())
                    .resizable()
                    .frame(width: 100, height: 100)
                    .cornerRadius(20)
                    .shadow(radius: 5)

                Text(appName)
                    .font(.title)
                    .fontWeight(.bold)

                Text(versionBuild)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(compileDate)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                VStack(spacing: 16) {
                    LinkButton(title: "Support", url: supportURL)
                    LinkButton(title: "Privacy Policy", url: privacyPolicyURL)
                    LinkButton(title: "Acknowledgements", url: acknowledgementsURL)
                }
                .padding(.top, 20)

                Spacer()

                Button("Dismiss") {
                    dismiss()
                }
                .padding(.vertical)
            }
            .padding()
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct LinkButton: View {
        let title: String
        let url: URL

        var body: some View {
            Button(action: {
                openURL(url)
            }) {
                Text(title)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(8)
            }
        }

        private func openURL(_ url: URL) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}

#Preview {
    AboutView()
}
