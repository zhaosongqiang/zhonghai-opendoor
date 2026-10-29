import SwiftUI

@main
struct OneTapDoorApp: App {
    @StateObject private var controller = DoorController()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                Button(action: controller.tap) {
                    VStack(spacing: 12) {
                        if controller.busy { ProgressView().tint(.white).scaleEffect(1.3) }
                        else { Image(systemName: "door.left.hand.open").font(.system(size: 42, weight: .medium)) }
                        Text(controller.label).font(.system(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 196, height: 196)
                    .background(Color(red: 0.05, green: 0.38, blue: 0.96), in: Circle())
                    .shadow(color: .blue.opacity(0.18), radius: 18, y: 8)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(controller.busy)
                .accessibilityLabel(controller.busy ? controller.label : "打开附近信号最强的已授权门禁")
            }
            .alert("手机开门", isPresented: Binding(get: { controller.message != nil }, set: { if !$0 { controller.message = nil } })) {
                Button("知道了", role: .cancel) { controller.message = nil }
            } message: { Text(controller.message ?? "") }
            .onChange(of: phase) { value in if value == .background { controller.cancelForBackground() } }
        }
    }
}
