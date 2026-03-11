import SwiftUI
import UIKit
import MessageUI

// MARK: - Feedback Helper

/// Serverless feedback: pre-filled email with device diagnostics.
enum FeedbackHelper {

    static let supportEmail = "cody@isolated.tech"

    // MARK: - Diagnostics

    /// Gathers non-identifying device/app info for bug reports.
    static var diagnosticsBlock: String {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let device = UIDevice.current.model          // "iPhone", "iPad"

        return """
        ---
        App: PocketREPL \(appVersion) (\(buildNumber))
        Platform: iOS \(osVersion)
        Device: \(device)
        """
    }

    // MARK: - Email

    /// Builds a mailto URL with pre-filled subject and diagnostics body.
    static func mailtoURL(subject: String = "PocketREPL Feedback") -> URL? {
        let body = "\n\n\(diagnosticsBlock)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    /// Whether the device can present the in-app mail compose sheet.
    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    /// Configures an `MFMailComposeViewController` for feedback.
    static func makeMailCompose() -> MFMailComposeViewController {
        let mc = MFMailComposeViewController()
        mc.setToRecipients([supportEmail])
        mc.setSubject("PocketREPL Feedback")
        mc.setMessageBody("\n\n\(diagnosticsBlock)", isHTML: false)
        return mc
    }
}

// MARK: - Mail Compose SwiftUI Wrapper

/// SwiftUI wrapper for `MFMailComposeViewController`.
struct MailComposeView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mc = FeedbackHelper.makeMailCompose()
        mc.mailComposeDelegate = context.coordinator
        return mc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposeView
        init(_ parent: MailComposeView) { self.parent = parent }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            parent.dismiss()
        }
    }
}
