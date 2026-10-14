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
    @StateObject private var ar = ARController.shared
    @State private var showMenu = false

    // 自定义 Binding: 双向连接 @Published 和视图
    private var bodyOn: Binding<Bool> {
        Binding(
            get: { ar.isBodyEnabled },
            set: { ar.isBodyEnabled = $0 }
        )
    }
    private var handsOn: Binding<Bool> {
        Binding(
            get: { ar.isHandsEnabled },
            set: { ar.isHandsEnabled = $0 }
        )
    }
    private var faceOn: Binding<Bool> {
        Binding(
            get: { ar.isFaceEnabled },
            set: { ar.isFaceEnabled = $0 }
        )
    }
    private var gridOn: Binding<Bool> {
        Binding(
            get: { ar.isGridEnabled },
            set: { ar.isGridEnabled = $0 }
        )
    }

    var body: some View {
        ZStack {
            // AR 渲染层 (RealityKit ARView)
            ARViewContainer(ar: ar)
                .ignoresSafeArea()

            // HUD 覆盖层
            HUDOverlay(ar: ar, bodyOn: bodyOn, handsOn: handsOn, faceOn: faceOn, gridOn: gridOn)

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
            MenuPanel(ar: ar, bodyOn: bodyOn, handsOn: handsOn, faceOn: faceOn, gridOn: gridOn)
                .applyDetents()
        }
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
