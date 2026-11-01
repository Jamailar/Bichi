import SwiftUI

/// 2 修复调整 — before/after split, per-tool strength slider.
struct EditScreen: View {
    @ObservedObject var session: EditSession
    @EnvironmentObject private var model: AppModel
    @State private var split: CGFloat = 0.5
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 16) {
            header
            ZStack {
                if session.phase == .analysing {
                    ProgressView("正在识别狗狗和毛发…").tint(Theme.accent)
                } else if case .failed(let msg) = session.phase {
                    Text(msg).foregroundStyle(Theme.warning)
                } else {
                    BeforeAfterView(before: session.previewOriginal, after: session.preview, split: $split)
                }
            }
            .frame(maxHeight: .infinity)
            if let a = session.analysis, a.landmarks == nil {
                Text(a.dogFound ? "没找到眼睛和鼻子，泪痕和嘴周请用「区域」手动涂抹" : "没识别到狗狗，只做整体去黄和高光")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            slider
            tools
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Button { model.path.removeAll() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("返回拍摄")
            Spacer()
            Button(action: session.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                .disabled(!session.canUndo).accessibilityLabel("撤销")
            Button(action: session.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                .disabled(!session.canRedo).accessibilityLabel("重做")
            Spacer()
            Button { model.path.append(.export) } label: {
                Text("导出").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(Capsule().fill(Theme.accent)).foregroundStyle(Theme.background)
            }
            .disabled(session.phase != .ready)
        }
        .padding(.horizontal, 12)
    }

    private var slider: some View {
        let tool = session.selectedTool
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tool.label + "强度").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(Int(session.value(for: tool).rounded()))")
                    .font(.system(size: 15).monospacedDigit()).foregroundStyle(Theme.accent)
            }
            Slider(
                value: Binding(get: { session.value(for: tool) }, set: { session.setValue($0, for: tool) }),
                in: 0...100,
                onEditingChanged: { editing in if editing { session.beginChange() } }
            )
            Text(tool.hint).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 20)
        .disabled(session.phase != .ready)
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(RetouchTool.allCases) { t in
                    let on = t == session.selectedTool
                    Button { session.selectedTool = t } label: {
                        VStack(spacing: 6) {
                            Text(t.glyph).font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(lineWidth: 1.5))
                            Text(t.label).font(.system(size: 12))
                        }
                        .frame(width: 58, height: 76)
                        .foregroundStyle(on ? Theme.accent : Theme.secondary)
                        .background(RoundedRectangle(cornerRadius: 14).fill(on ? Theme.accent.opacity(0.14) : .clear))
                    }
                }
                Button { model.path.append(.mask) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "paintbrush.pointed")
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                        Text("区域").font(.system(size: 12))
                    }
                    .frame(width: 58, height: 76)
                    .foregroundStyle(Theme.secondary)
                }
                .disabled(session.phase != .ready)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 96)
    }
}

/// Draggable split between original (left) and result (right).
struct BeforeAfterView: View {
    let before: CGImage?
    let after: CGImage?
    @Binding var split: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                image(after)
                image(before)
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * split) }
                Rectangle().fill(.white).frame(width: 2)
                    .offset(x: geo.size.width * split - 1)
                Circle().fill(.white).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "arrow.left.and.right").foregroundStyle(Theme.background))
                    .offset(x: geo.size.width * split - 22, y: geo.size.height / 2 - 22)
                    .accessibilityLabel("拖动对比分界线")
                HStack {
                    tag("原图", color: Theme.text)
                    Spacer()
                    tag("修复后", color: Theme.accent)
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                split = min(max(v.location.x / geo.size.width, 0), 1)
            })
        }
    }

    private func image(_ cg: CGImage?) -> some View {
        Group {
            if let cg { Image(decorative: cg, scale: 1).resizable().scaledToFit() } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tag(_ s: String, color: Color) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(color)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(Theme.background.opacity(0.72)))
    }
}
