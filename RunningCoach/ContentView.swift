import SwiftUI

struct ContentView: View {
    @State private var isWebReady = false

    var body: some View {
        ZStack {
            RunContextWebView {
                withAnimation(.easeOut(duration: 0.28)) {
                    isWebReady = true
                }
            }
            .background(RunContextColors.swiftUIBackground)
            .ignoresSafeArea()

            if !isWebReady {
                PaceLabSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .background(RunContextColors.swiftUIBackground)
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
