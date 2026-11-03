import SwiftUI
import GoogleSignInSwift

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.columbiaBlue, Theme.navy], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
                Text("Campus Events")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Snap a flyer, swipe, and it's on your calendar.\nNever miss a talk again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()

                GoogleSignInButton(scheme: .light, style: .wide, state: .normal) {
                    Task { await auth.signIn() }
                }
                .padding(.horizontal, 32)

                Text("Sign in with your @barnard.edu or @columbia.edu account. We only ask for permission to add and edit events on your Google Calendar.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .alert("Couldn't sign in", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(auth.errorMessage ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { auth.errorMessage != nil }, set: { if !$0 { auth.errorMessage = nil } })
    }
}
