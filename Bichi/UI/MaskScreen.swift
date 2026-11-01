import SwiftUI

/// 3 区域微调 — show the auto masks, paint to add or erase.
struct MaskScreen: View {
    @ObservedObject var session: EditSession
    @EnvironmentObject private var model: AppModel
    @State private var visible: Set<RetouchRegion> = [.tear, .mouth]
    @State private var active: RetouchRegion = .tear
    @State private var mode: BrushStroke.Mode = .add
    @State private var brush: Double = 18
    @State private var current: [CGPoint] = []
    @State private var overlay: CGImage?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("完成") { model.path.removeLast() }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Text("区域微调").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("撤销", action: { session.undo(); refresh() })
                    .foregroundStyle(Theme.secondary).disabled(!session.canUndo)
            }
            .padding(.horizontal, 20).frame(height: 44)

            canvas.frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(RetouchRegion.allCases) { r in
                        let on = visible.contains(r)
                        Button {
                            if on { visible.remove(r) } else { visible.insert(r); active = r }
                            refresh()
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color(r)).frame(width: 10, height: 10)
                                Text(r.label).font(.system(size: 13))
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(Capsule().fill(on ? Theme.surfaceRaised : .clear))
                            .overlay(Capsule().stroke(active == r ? Theme.accent : Color(hex: 0x2E3136)))
                        }
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                HStack(spacing: 10) {
                    modeButton("涂抹增加", .add)
                    modeButton("擦除", .erase)
                }
                HStack(spacing: 12) {
                    Text("画笔大小").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                    Slider(value: $brush, in: 8...40)
                }
                Text("正在编辑「\(active.label)」。系统已自动识别各个区域，涂抹可以增加或减少修复范围，范围外的毛发和背景保持原样。")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: refresh)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let rect = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let p = session.preview {
                    Image(decorative: p, scale: 1).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }
                if let o = overlay {
                    Image(decorative: o, scale: 1).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                }
                Path { path in
                    guard let f = current.first else { return }
                    path.move(to: f); current.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: brush * 2, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { current.append($0.location) }
                .onEnded { _ in commit(in: rect) })
        }
    }

    private func modeButton(_ title: String, _ m: BrushStroke.Mode) -> some View {
        Button { mode = m } label: {
            Text(title).font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(mode == m ? Theme.accent : Theme.surface))
                .foregroundStyle(mode == m ? Theme.background : Theme.text)
        }
    }

    private func color(_ r: RetouchRegion) -> Color {
        switch r {
        case .tear: Theme.warning
        case .mouth: Theme.mouth
        case .eyes: .white
        case .fur: Theme.accent
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        guard let a = session.analysis else { return CGRect(origin: .zero, size: size) }
        let s = min(size.width / a.size.width, size.height / a.size.height)
        let w = a.size.width * s, h = a.size.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// View points → normalised image points, bottom-left origin.
    private func commit(in rect: CGRect) {
        defer { current = [] }
        guard !current.isEmpty, rect.width > 0 else { return }
        let pts = current.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: 1 - ($0.y - rect.minY) / rect.height) }
        session.addStroke(BrushStroke(region: active, mode: mode, radius: brush / rect.width, points: pts))
        refresh()
    }

    private func refresh() {
        overlay = session.maskOverlay(visible: visible)
    }
}
