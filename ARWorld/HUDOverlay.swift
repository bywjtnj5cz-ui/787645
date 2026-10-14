import SwiftUI
import ARKit

// MARK: - 游戏风格 HUD 覆盖层
struct HUDOverlay: View {
    @ObservedObject var ar: ARController
    @Binding var bodyOn: Bool
    @Binding var handsOn: Bool
    @Binding var faceOn: Bool
    @Binding var gridOn: Bool

    var body: some View {
        ZStack {
            // 四角括号
            VStack {
                HStack {
                    cornerPair
                    Spacer()
                    cornerPairFlipped
                }
                Spacer()
                HStack {
                    cornerPairBottom
                    Spacer()
                    cornerPairBottomFlipped
                }
            }

            // 中心准星
            Image(systemName: "crosshexagon")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.cyan)
                .opacity(0.6)

            // 状态面板 (左上)
            VStack(alignment: .leading, spacing: 6) {
                statusLine("AR-WORLD v2.0  //  NATIVE", color: .cyan)
                statusLine(String(format: "FPS %5.1f", ar.fps), color: .cyan)
                statusLine("TRK  \(ar.trackingState)", color: ar.trackingState=="TRACK" ? .green : .orange)
                statusLine("DEPTH \(ar.depthAvailable ? "ON(LiDAR)" : "OFF")", color: ar.depthAvailable ? .green : .gray)
                if ar.isBodyEnabled {
                    statusLine(String(format: "BODY  %.2f", ar.lastBodyConfidence), color: .green)
                }
                if ar.isHandsEnabled {
                    statusLine("HANDS \(ar.lastHandCount)", color: .orange)
                }
                if ar.isFaceEnabled {
                    statusLine(String(format: "FACE  %.2f", ar.lastFaceConfidence), color: .purple)
                }
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.cyan)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.35), lineWidth: 1))
            .padding(.top, 50)
            .padding(.leading, 16)

            // 顶部罗盘 (中上方)
            CompassHUD(trackingState: ar.trackingState)
                .padding(.top, 44)

            // 底部骨骼开关条 (紧凑)
            HStack(spacing: 10) {
                hudToggle(label: "BODY", on: $bodyOn, accent: .green)
                hudToggle(label: "HAND", on: $handsOn, accent: .orange)
                hudToggle(label: "FACE", on: $faceOn, accent: .purple)
                hudToggle(label: "GRID", on: $gridOn, accent: .cyan)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 1))
            .padding(.bottom, 90)
        }
    }

    func statusLine(_ t: String, color: Color) -> some View {
        HStack(spacing: 0) {
            Text("> ")
                .foregroundColor(color)
                .opacity(0.8)
            Text(t)
                .foregroundColor(color)
        }
    }

    var cornerPair: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.cyan).frame(width: 22, height: 2)
            Rectangle().fill(Color.cyan).frame(width: 2, height: 22)
        }
        .opacity(0.55)
        .padding(.top, 14)
        .padding(.leading, 14)
    }
    var cornerPairFlipped: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Rectangle().fill(Color.cyan).frame(width: 22, height: 2)
            Rectangle().fill(Color.cyan).frame(width: 2, height: 22)
        }
        .opacity(0.55)
        .padding(.top, 14)
        .padding(.trailing, 14)
    }
    var cornerPairBottom: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.cyan).frame(width: 2, height: 22)
            Rectangle().fill(Color.cyan).frame(width: 22, height: 2)
        }
        .opacity(0.55)
        .padding(.bottom, 14)
        .padding(.leading, 14)
    }
    var cornerPairBottomFlipped: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.cyan).frame(width: 2, height: 22)
            Rectangle().fill(Color.cyan).frame(width: 22, height: 2)
        }
        .opacity(0.55)
        .padding(.bottom, 14)
        .padding(.trailing, 14)
    }

    func hudToggle(label: String, on: Binding<Bool>, accent: Color) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(on.wrappedValue ? accent : Color.gray)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(on.wrappedValue ? accent : .gray)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 简易罗盘 HUD (需要 heading 数据源, 这里用 trackingState 占位)
struct CompassHUD: View {
    let trackingState: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(["N","NE","E","SE","S","SW","W","NW"], id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(name == "N" ? .cyan : .cyan.opacity(0.45))
                    .frame(width: 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(Color.cyan.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - 设置菜单
struct MenuPanel: View {
    @ObservedObject var ar: ARController
    @Binding var bodyOn: Bool
    @Binding var handsOn: Bool
    @Binding var faceOn: Bool
    @Binding var gridOn: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("SKELETON MODULES") {
                    Toggle("Full Body (33 pts)", isOn: $bodyOn)
                    Toggle("Both Hands (21 pts each)", isOn: $handsOn)
                    Toggle("Face Mesh (468 pts)", isOn: $faceOn)
                }
                Section("WORLD") {
                    Toggle("Ground Grid", isOn: $gridOn)
                    Button("Reset AR Tracking") {
                        // 重建 session
                        let config = ARWorldTrackingConfiguration()
                        config.frameSemantics.insert(.depthData)
                        config.frameSemantics.insert(.smoothedDepthData)
                        ar.arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                    }
                }
                Section("HARDWARE") {
                    HStack { Text("Depth / LiDAR"); Spacer(); Text(ar.depthAvailable ? "ON" : "OFF").foregroundColor(ar.depthAvailable ? .green : .gray) }
                    HStack { Text("AR Tracking"); Spacer(); Text(ar.trackingState).foregroundColor(ar.trackingState=="TRACK" ? .green : .orange) }
                    HStack { Text("Vision Frames/s"); Spacer(); Text(String(format: "%.0f", ar.fps)).foregroundColor(.cyan) }
                }
                Section("PERFORMANCE TIP") {
                    Text("关闭不需要的模块可显著提升帧率。Face Mesh 计算开销最大(约 10-15ms/帧),Body 最稳定。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("AR-WORLD SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
