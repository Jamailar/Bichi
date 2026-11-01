import Foundation

/// The tools on the "修复调整" screen. Values are 0...1 (the UI shows 0...100).
enum RetouchTool: String, CaseIterable, Codable, Identifiable {
    case auto, tear, mouth, whiten, highlight, eyes
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "一键"
        case .tear: "泪痕"
        case .mouth: "嘴周"
        case .whiten: "去黄"
        case .highlight: "高光"
        case .eyes: "眼鼻"
        }
    }

    var glyph: String {
        switch self {
        case .auto: "A"
        case .tear: "泪"
        case .mouth: "嘴"
        case .whiten: "白"
        case .highlight: "光"
        case .eyes: "眼"
        }
    }

    var hint: String {
        switch self {
        case .auto: "自动识别泪痕、嘴周染色、偏黄和过曝，一次修好"
        case .tear: "只淡化眼下的红褐色，保留原有毛发纹理"
        case .mouth: "去掉嘴边被口水和食物染出的黄褐色"
        case .whiten: "校正整只狗的偏黄、偏灰，背景颜色不受影响"
        case .highlight: "找回过曝白毛里的层次"
        case .eyes: "让被毛遮住的眼睛和鼻头更清楚、更有神"
        }
    }
}

/// Regions on the "区域微调" screen.
enum RetouchRegion: String, CaseIterable, Codable, Identifiable {
    case tear, mouth, eyes, fur
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tear: "泪痕"
        case .mouth: "嘴周"
        case .eyes: "眼鼻"
        case .fur: "全身毛发"
        }
    }
}

struct RetouchParameters: Equatable, Codable {
    /// Master for "一键": scales the analyser's suggestion into every tool.
    var auto: Double = 0.8
    var tear: Double = 0
    var mouth: Double = 0
    var whiten: Double = 0
    var highlight: Double = 0
    var eyes: Double = 0

    static let none = RetouchParameters(auto: 0)

    subscript(tool: RetouchTool) -> Double {
        get {
            switch tool {
            case .auto: auto
            case .tear: tear
            case .mouth: mouth
            case .whiten: whiten
            case .highlight: highlight
            case .eyes: eyes
            }
        }
        set {
            let v = min(max(newValue, 0), 1)
            switch tool {
            case .auto: auto = v
            case .tear: tear = v
            case .mouth: mouth = v
            case .whiten: whiten = v
            case .highlight: highlight = v
            case .eyes: eyes = v
            }
        }
    }

    /// "一键" at `strength`: every tool becomes suggestion × strength.
    static func auto(_ suggestion: RetouchParameters, strength: Double) -> RetouchParameters {
        var p = RetouchParameters(auto: strength)
        for tool in RetouchTool.allCases where tool != .auto {
            p[tool] = suggestion[tool] * strength
        }
        return p
    }
}
