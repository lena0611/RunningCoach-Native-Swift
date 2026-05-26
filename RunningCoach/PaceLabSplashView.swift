import SwiftUI

struct PaceLabSplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 7 / 255, green: 11 / 255, blue: 18 / 255),
                    Color(red: 11 / 255, green: 15 / 255, blue: 20 / 255)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255).opacity(0.12))
                    .frame(width: 360, height: 360)
                    .blur(radius: 78)
                    .offset(x: 110, y: -140)
            }
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(Color.indigo.opacity(0.14))
                    .frame(width: 320, height: 320)
                    .blur(radius: 92)
                    .offset(x: -120, y: 130)
            }

            VStack(spacing: 24) {
                PaceLabMark()
                    .frame(width: 92, height: 92)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255).opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255).opacity(0.3), lineWidth: 1)
                            )
                    )

                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Text("PACE")
                            .foregroundStyle(.white)
                        Text("LAB")
                            .foregroundStyle(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255))
                    }
                    .font(.system(size: 40, weight: .black, design: .default).italic())

                    Text("AI POWERED TRAINING LAB")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255))
                        .tracking(4)
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct PaceLabMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = size * 0.105
            ZStack {
                Circle()
                    .stroke(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255), lineWidth: line)
                    .frame(width: size * 0.72, height: size * 0.72)
                Circle()
                    .stroke(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255), lineWidth: line * 0.78)
                    .frame(width: size * 0.37, height: size * 0.37)
                Circle()
                    .fill(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255))
                    .frame(width: size * 0.11, height: size * 0.11)
                Capsule()
                    .fill(Color(red: 7 / 255, green: 11 / 255, blue: 18 / 255))
                    .frame(width: size * 0.5, height: line * 1.25)
                    .rotationEffect(.degrees(-45))
                    .offset(x: size * 0.15, y: -size * 0.15)
                Capsule()
                    .fill(Color(red: 214 / 255, green: 255 / 255, blue: 53 / 255))
                    .frame(width: size * 0.47, height: line * 0.55)
                    .rotationEffect(.degrees(-45))
                    .offset(x: size * 0.15, y: -size * 0.15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    PaceLabSplashView()
}
