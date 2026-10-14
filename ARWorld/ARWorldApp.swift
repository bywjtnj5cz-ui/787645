import SwiftUI
import ARKit
import RealityKit

@main
struct ARWorldApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - ContentView (SwiftUI 主界面)
struct ContentView: View {
    // AR 状态(由 ARController 驱动,SwiftUI 观察)
    @StateObject private var ar = ARController.shared
    @State private var showMenu = false
    @State private var bodyOn = true
    @State private var handsOn = true
    @State private var faceOn = true
    @State private var gridOn = true

    var body: some View {
        ZStack {
            // AR 渲染层 (RealityKit ARView)
            ARViewContainer(ar: ar)
                .ignoresSafeArea()

            // HUD 覆盖层
            HUDOverlay(ar: ar, bodyOn: $bodyOn, handsOn: $handsOn, faceOn: $faceOn, gridOn: $gridOn)

            // 菜单按钮
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        withAnimation { showMenu.toggle() }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 100)
                }
            }
        }
        .sheet(isPresented: $showMenu) {
            MenuPanel(ar: ar, bodyOn: $bodyOn, handsOn: $handsOn, faceOn: $faceOn, gridOn: $gridOn)
                .applyDetents()
        }
        .onChange(of: bodyOn) { newValue in ar.isBodyEnabled = newValue }
        .onChange(of: handsOn) { newValue in ar.isHandsEnabled = newValue }
        .onChange(of: faceOn) { newValue in ar.isFaceEnabled = newValue }
        .onChange(of: gridOn) { newValue in ar.isGridEnabled = newValue }
        .task {
            ar.start()
        }
    }
}

// MARK: - RealityKit ARView 桥接到 SwiftUI
struct ARViewContainer: UIViewRepresentable {
    let ar: ARController

    func makeUIView(context: Context) -> ARView {
        ar.arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - presentationDetents 可用性封装 (iOS 16+)
extension View {
    @ViewBuilder
    func applyDetents() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}
