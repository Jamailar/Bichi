import SwiftUI

@main
struct BichiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Route: Hashable {
    case edit, mask, export
}

@MainActor
final class AppModel: ObservableObject {
    @Published var path: [Route] = []
    @Published var session: EditSession?

    func open(_ data: Data) {
        guard let s = EditSession(data: data) else { return }
        session = s
        path = [.edit]
    }
}

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationStack(path: $model.path) {
            CaptureScreen()
                .navigationDestination(for: Route.self) { route in
                    if let session = model.session {
                        switch route {
                        case .edit: EditScreen(session: session)
                        case .mask: MaskScreen(session: session)
                        case .export: ExportScreen(session: session)
                        }
                    }
                }
        }
        .environmentObject(model)
    }
}

/// Colours from the "设计白狗美颜相机 iOS 界面" canvas.
enum Theme {
    static let background = Color(hex: 0x0E0F11)
    static let surface = Color(hex: 0x1C1E22)
    static let surfaceRaised = Color(hex: 0x23262B)
    static let text = Color(hex: 0xF4F4F2)
    static let secondary = Color(hex: 0xC9CBCF)
    static let tertiary = Color(hex: 0x9A9DA3)
    static let accent = Color(hex: 0x7FD6C8)
    static let warning = Color(hex: 0xF2B66B)
    static let mouth = Color(hex: 0x8FB8FF)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
