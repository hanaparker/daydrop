import Combine
import Foundation
import GoogleSignIn
import UIKit

enum AuthError: LocalizedError {
    case wrongDomain(String)
    case calendarAccessDenied
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .wrongDomain(let email):
            return "\(email) isn't a Barnard or Columbia account. Sign in with your @barnard.edu or @columbia.edu email."
        case .calendarAccessDenied:
            return "Calendar access is needed to add events. Please sign in again and allow access."
        case .notSignedIn:
            return "You're signed out. Sign in again to sync with Google Calendar."
        }
    }
}

/// Google sign-in, limited to Barnard and Columbia accounts (both run on Google Workspace).
@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    // TODO: remove gmail.com before release — testing only
    static let allowedDomains = ["barnard.edu", "columbia.edu", "gmail.com"]
    /// Lets the app create, edit and delete events — nothing else in the student's account.
    static let calendarScope = "https://www.googleapis.com/auth/calendar.events"

    @Published private(set) var user: GIDGoogleUser?
    @Published private(set) var isRestoring = true
    @Published var errorMessage: String?

    var isSignedIn: Bool { user != nil }
    var email: String? { user?.profile?.email }

    private init() {
        Task { await restore() }
    }

    func restore() async {
        defer { isRestoring = false }
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        do {
            let restored = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            try accept(restored)
        } catch {
            user = nil
        }
    }

    func signIn() async {
        guard let presenter = UIApplication.shared.topViewController else { return }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [Self.calendarScope]
            )
            try accept(result.user)
        } catch let error as AuthError {
            GIDSignIn.sharedInstance.signOut()
            errorMessage = error.localizedDescription
        } catch let error as GIDSignInError where error.code == .canceled {
            // The student closed the sign-in sheet; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
    }

    /// A fresh OAuth access token for Google Calendar API calls.
    func accessToken() async throws -> String {
        if user == nil { await restore() }
        guard let user else { throw AuthError.notSignedIn }
        let refreshed = try await user.refreshTokensIfNeeded()
        return refreshed.accessToken.tokenString
    }

    private func accept(_ user: GIDGoogleUser) throws {
        let email = user.profile?.email.lowercased() ?? ""
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        guard Self.allowedDomains.contains(domain) else {
            throw AuthError.wrongDomain(email.isEmpty ? "That account" : email)
        }
        guard user.grantedScopes?.contains(Self.calendarScope) == true else {
            throw AuthError.calendarAccessDenied
        }
        self.user = user
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
