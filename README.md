# Bichi 白狗美颜相机（iOS）

专为比熊、博美、马尔济斯等白色狗狗做的相机：拍摄时防止白毛过曝，拍完后在设备上修复泪痕、嘴周染色、偏黄偏灰和被毛遮住的眼鼻。**所有处理都是对原始像素按比例调色，不做生成式重绘**，毛发纹理是相机真实拍到的。

## 构建

本仓库不提交 `.xcodeproj`，用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成：

```sh
brew install xcodegen
xcodegen generate
open Bichi.xcodeproj
```

要求 Xcode 16+、iOS 17+（用到 `VNGenerateForegroundInstanceMaskRequest` 和 `VNDetectAnimalBodyPoseRequest`）。真机运行需在 Signing 里选自己的 Team。GitHub Actions 会在 macOS 上编译并在模拟器上跑单元测试（`.github/workflows/ios.yml`）。

## 结构

| 目录 | 内容 |
|---|---|
| `Bichi/Capture` | `CameraController`：AVFoundation 会话；按狗毛而不是整幅画面测光，白毛过曝就逐步降 EV；对焦/测光点放在 Vision 找到的眼睛上；「锁定」时锁曝光，并以狗毛当灰卡算白平衡增益。`FurExposureMeter`：取景帧的白毛高光统计与纯逻辑控制器 |
| `Bichi/Processing` | `FurAnalyzer`：Vision 识别狗 → 前景实例分割出狗的蒙版 → 动物姿态关键点（双眼、鼻子）→ 生成泪痕/嘴周/眼鼻/全身毛发区域，并从干净毛发估计这只狗的"白"。`FurKernels.ci.metal`：Core Image Metal 内核。`FurProcessor`：按顺序合成。`ColorMath.swift`：内核数学的 Swift 镜像，用于单元测试 |
| `Bichi/Editing` | `EditSession`：参数、画笔、撤销重做、预览渲染与全尺寸导出 |
| `Bichi/UI` | 对应设计稿的 5 屏：拍摄、修复调整、区域微调、导出、相册导入（PhotosPicker） |

处理顺序与原理见 [docs/pipeline.md](docs/pipeline.md)。

## 现状

- 这些代码是在没有 Xcode 的环境里写的，**画质和性能都还没在真机上验证过**。CI 只能证明能编译、内核数学和合成逻辑在合成测试图上行为正确。
- 服务端：v1 全部在设备上完成，不需要后端。以后如需云端（例如账号、模板下发、统计），走 `ArtiSalesBackend` 的共享网关。
- 安卓版之后再做；`docs/pipeline.md` 里的算法与平台无关，可以直接移植。
