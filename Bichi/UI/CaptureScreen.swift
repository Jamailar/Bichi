import PhotosUI
import SwiftUI

/// 1 拍摄 — camera with fur-aware metering and the lock chip.
struct CaptureScreen: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var camera = CameraController()
    @State private var pickerItem: PhotosPickerItem?
    @State private var capturing = false

    var body: some View {
        VStack(spacing: 12) {
            topBar
            viewfinder
            Spacer(minLength: 0)
            controls
        }
        .padding(.top, 8)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .toolbar(.hidden, for: .navigationBar)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.open(data) }
                pickerItem = nil
            }
        }
    }

    private var topBar: some View {
        HStack {
            Toggle(isOn: Binding(get: { camera.furMetering }, set: { camera.setFurMetering($0) })) {
                Image(systemName: "sun.max")
            }
            .toggleStyle(.button)
            .accessibilityLabel("白毛测光")
            Spacer()
            Button(action: camera.toggleLock) {
                Label(camera.isLocked ? "曝光 · 白平衡已锁定" : "锁定曝光 · 白平衡",
                      systemImage: camera.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 36)
                    .foregroundStyle(camera.isLocked ? Theme.accent : Theme.text)
                    .background(Capsule().fill(camera.isLocked ? Theme.accent.opacity(0.12) : Theme.surface))
                    .overlay(Capsule().stroke(camera.isLocked ? Theme.accent : .clear))
            }
            .disabled(!camera.dogDetected && !camera.isLocked)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CameraPreview(session: camera.session)
                if let box = camera.dogBox {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                        .frame(width: box.width * geo.size.width, height: box.height * geo.size.height)
                        .offset(x: box.minX * geo.size.width, y: box.minY * geo.size.height)
                }
                if let eye = camera.eyeBox {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.warning, lineWidth: 2)
                        .frame(width: eye.width * geo.size.width, height: eye.height * geo.size.height)
                        .offset(x: eye.minX * geo.size.width, y: eye.minY * geo.size.height)
                }
                hud.padding(12)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipped()
    }

    private var hud: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                if camera.dogDetected {
                    Label("已识别狗狗 · 白色毛发", systemImage: "circle.fill")
                        .labelStyle(DotLabel())
                }
                Spacer()
                HighlightMeterView(clipped: camera.furClipped)
            }
            Spacer()
            if camera.dogDetected {
                Text(camera.exposureBias < -0.05
                     ? String(format: "对焦在眼睛 · 已为白毛降低 %.1f EV", -camera.exposureBias)
                     : "对焦在眼睛")
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.background.opacity(0.8)))
            }
        }
    }

    private var controls: some View {
        HStack {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.surface)
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "photo.on.rectangle"))
            }
            .accessibilityLabel("打开相册")
            Spacer()
            Button {
                guard !capturing else { return }
                capturing = true
                Task {
                    defer { capturing = false }
                    if let data = try? await camera.capturePhoto() { model.open(data) }
                }
            } label: {
                Circle().stroke(Theme.text, lineWidth: 4).frame(width: 80, height: 80)
                    .overlay(Circle().fill(Theme.text).frame(width: 62, height: 62))
            }
            .accessibilityLabel("拍摄")
            Spacer()
            Color.clear.frame(width: 52, height: 52)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
}

struct HighlightMeterView: View {
    let clipped: Float
    private var blown: Bool { clipped > FurExposureController.clipLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("白毛高光").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            GeometryReader { g in
                Capsule().fill(Color(hex: 0x33363C))
                    .overlay(alignment: .leading) {
                        Capsule().fill(blown ? Theme.warning : Theme.accent)
                            .frame(width: g.size.width * CGFloat(1 - min(clipped * 20, 1)))
                    }
            }
            .frame(height: 6)
            Text(blown ? "有过曝" : "未过曝")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(blown ? Theme.warning : Theme.accent)
        }
        .padding(8)
        .frame(width: 92)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.background.opacity(0.72)))
    }
}

struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
            configuration.title
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(Theme.background.opacity(0.72)))
    }
}
