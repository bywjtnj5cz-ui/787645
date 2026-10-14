import Foundation
import ARKit
import RealityKit
import Vision
import Combine
import UIKit

// MARK: - 共享控制器 (AR + Vision + 3D 渲染 协调者)
@MainActor
final class ARController: ObservableObject {
    static let shared = ARController()

    let arView: ARView
    let arSession: ARSession
    let visionQueue = DispatchQueue(label: "com.arworld.vision", qos: .userInitiated)

    // 开关
    @Published var isBodyEnabled = true
    @Published var isHandsEnabled = true
    @Published var isFaceEnabled = true
    @Published var isGridEnabled = true

    // 状态面板数据
    @Published var fps: Double = 0
    @Published var trackingState: String = "INIT"
    @Published var depthAvailable: Bool = false
    @Published var lastBodyConfidence: Double = 0
    @Published var lastHandCount: Int = 0
    @Published var lastFaceConfidence: Double = 0

    // 3D 实体容器 (每种骨骼一个锚点)
    private let bodyAnchor = Entity()
    private let leftHandAnchor = Entity()
    private let rightHandAnchor = Entity()
    private let faceAnchor = Entity()
    private let gridAnchor = Entity()
    private var gridEntities: [Entity] = []

    // 上一帧时间戳 (FPS 计算 + 丢帧)
    private var lastFrameTime: CFTimeInterval = 0
    private var lastVisionFrame: CFTimeInterval = 0

    // 模型实体缓存 (避免每帧重新创建 mesh)
    private var bodyJoints: [Int: Entity] = [:]
    private var bodyEdges: [Entity] = []
    private var handJoints: [Int: Entity] = [:]  // 双手用合并 key (hand * 100 + index)
    private var handEdges: [Entity] = []
    private var faceMesh: ModelEntity?
    private var faceJoints: [Int: Entity] = [:]

    private init() {
        // RealityKit ARView, 启用 LiDAR 深度
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.depthData)       // LiDAR 深度
        config.frameSemantics.insert(.smoothedDepthData)
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView = ARView(frame: .zero,
                        cameraMode: .ar,
                        automaticallyConfigureSession: false)
        arView.session = ARSession()
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.session.delegate = self

        arView.scene.addAnchor(bodyAnchor)
        arView.scene.addAnchor(leftHandAnchor)
        arView.scene.addAnchor(rightHandAnchor)
        arView.scene.addAnchor(faceAnchor)
        arView.scene.addAnchor(gridAnchor)

        setupGrid()
    }

    func start() {
        // ARSession 已经在 init 里 run 了,这里触发一次 UI 更新
    }

    // MARK: - 地面网格 (AR 世界坐标系原点)
    private func setupGrid() {
        let step: Float = 1.0
        let extent: Float = 8.0
        gridEntities.forEach { gridAnchor.removeChild($0) }
        gridEntities.removeAll()
        for x in stride(from: -extent, through: extent, by: step) {
            for z in stride(from: -extent, through: extent, by: step) {
                let node = ModelEntity(
                    mesh: .generateBox(size: [0.02, 0.005, 0.02]),
                    materials: [SimpleMaterial(color: .cyan.withAlphaComponent(0.3), roughness: 0, isMetallic: false)])
                node.position = [x, 0, z]
                gridAnchor.addChild(node)
                gridEntities.append(node)
            }
        }
        gridAnchor.isEnabled = isGridEnabled
    }
}

// MARK: - ARSessionDelegate (每帧驱动 Vision)
extension ARController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 跟踪状态
        switch frame.camera.trackingState {
        case .normal:  trackingState = "TRACK"
        case .limited(let reason):
            switch reason {
            case .initializing: trackingState = "INIT"
            case .excessiveMotion: trackingState = "MOTION"
            case .insufficientFeatures: trackingState = "FEATURE"
            case .relocalizing: trackingState = "RELOC"
            @unknown default: trackingState = "?"
            }
        case .notAvailable: trackingState = "NO_AR"
        @unknown default: break
        }

        // 深度可用?
        depthAvailable = frame.depthData != nil

        // FPS
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0, dt < 1 { fps = fps * 0.8 + (1/dt) * 0.2 }
        }
        lastFrameTime = now

        // 丢帧策略:Vision 在后台跑,主线程 ARSessionDelegate 里每 2-3 帧喂一次(看机型)
        // iPad/LiDAR 机型帧间间隔小,iPhone 旧机型帧间隔大,统一阈值 40ms
        guard now - lastVisionFrame > 0.04 else { return }
        lastVisionFrame = now

        // 复制当前 frame,送到 Vision 队列
        let frameCopy = frame
        visionQueue.async { [weak self] in
            Task { @MainActor in self?.runVision(frame: frameCopy) }
        }
    }
}

// MARK: - Vision 请求链 (Pose + Hand × 2 + FaceLandmarks)
extension ARController {
    func runVision(frame: ARFrame) {
        let orientation = CGImagePropertyOrientation.right  // 后置摄像头竖屏
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage,
                                            orientation: orientation,
                                            options: [:])
        var requests: [VNRequest] = []

        if isBodyEnabled {
            let pose = VNDetectHumanBodyPoseRequest()
            pose.maximumHumanBodyPoseCount = 1
            requests.append(pose)
        }
        if isHandsEnabled {
            let hand = VNDetectHumanHandPoseRequest()
            hand.maximumHandCount = 2
            requests.append(hand)
        }
        if isFaceEnabled {
            let face = VNDetectFaceLandmarksRequest()
            face.maximumFaceCount = 1
            requests.append(face)
        }
        guard !requests.isEmpty else {
            clearAllAnchors()
            return
        }

        do {
            try handler.perform(requests)
        } catch {
            print("[Vision] error:", error)
            clearAllAnchors()
            return
        }

        // 解析结果 (都在主线程,直接消费 ARFrame.camera 和 depth)
        // body: first result (VNHumanBodyPose3D? iOS 15+ 直接 3D)
        // body 在 iOS 15+ 返回 3D 关键点 (VNRecognizedPoints3D),省去反投影
        if isBodyEnabled, let pose = requests.first(where: { $0 is VNDetectHumanBodyPoseRequest }) as? VNDetectHumanBodyPoseRequest {
            if let results = pose.results, !results.isEmpty {
                updateBody(from: results[0], frame: frame)
            } else {
                clearBody()
            }
        } else if isBodyEnabled {
            clearBody()
        }

        // hands
        if isHandsEnabled {
            // 请求顺序:body, hand, face。找 VNDetectHumanHandPoseRequest
            if let handReq = requests.first(where: { $0 is VNDetectHumanHandPoseRequest }) as? VNDetectHumanHandPoseRequest {
                let handResults = handReq.results ?? []
                lastHandCount = handResults.count
                if handResults.count >= 2 {
                    updateHand(from: handResults[0], isLeft:  true,  frame: frame)
                    updateHand(from: handResults[1], isLeft:  false, frame: frame)
                } else if handResults.count == 1 {
                    updateHand(from: handResults[0], isLeft:  true,  frame: frame)
                    clearHand(isLeft: false)
                } else {
                    clearHand(isLeft: true)
                    clearHand(isLeft: false)
                }
            }
        } else {
            clearHand(isLeft: true); clearHand(isLeft: false)
        }

        // face
        if isFaceEnabled {
            if let faceReq = requests.first(where: { $0 is VNDetectFaceLandmarksRequest }) as? VNDetectFaceLandmarksRequest {
                if let results = faceReq.results, let faceObs = results.first {
                    updateFace(from: faceObs, frame: frame)
                } else {
                    clearFace()
                }
            }
        } else {
            clearFace()
        }

        gridAnchor.isEnabled = isGridEnabled
    }
}

// MARK: - 身体骨骼 (33 点)
extension ARController {
    func updateBody(from body: VNRecognizedPoints3D, frame: ARFrame) {
        // Vision 返回的是 ARWorld 坐标系下的 3D 点 (iOS 15+)
        // 用 .center 做跟踪参考点
        guard let joints = try? body.recognizedPoints(.all) else { clearBody(); return }
        lastBodyConfidence = joints.values.compactMap { $0.confidence }.min() ?? 0

        // 33 关键点 ID → RealityKit Entity
        for (rawIdx, rawPt) in joints {
            let idx = rawIdx.rawValue
            guard let pt = rawPt.location else { continue }
            let worldPos = simd_float3(x: pt.x, y: pt.y, z: pt.z)
            // 关节点球体 (复用已存在的 Entity 避免 GC)
            let node = bodyJoints[idx] ?? makeJoint(color: .green, radius: 0.015)
            node.position = worldPos
            if bodyJoints[idx] == nil {
                bodyAnchor.addChild(node); bodyJoints[idx] = node
            }
        }
        drawBodyEdges(joints)
    }

    // Vision 不返回 "边", 我们自己根据身体拓扑连线
    // 这里用简化拓扑, 覆盖躯干 + 四肢 + 头
    func drawBodyEdges(_ joints: [VNJointName3D: VNPoint3D]) {
        // 清旧线
        bodyEdges.forEach { bodyAnchor.removeChild($0) }
        bodyEdges.removeAll()

        // 身体拓扑对 (VNJointName3D 的 rawValue 是 Int)
        let pairs: [(Int,Int,UIColor,Float)] = [
            // 躯干
            (0, 11, .green, 0.008), (0, 12, .green, 0.008),
            (11, 12, .green, 0.008), (11, 13, .green, 0.008),
            (12, 14, .green, 0.008),
            // 头
            (0, 1, .green, 0.008), (1, 2, .green, 0.008),
            (2, 3, .green, 0.008), (3, 7, .green, 0.008),
            (0, 4, .green, 0.008), (4, 5, .green, 0.008),
            (5, 6, .green, 0.008), (6, 8, .green, 0.008),
            // 右臂
            (14, 16, .cyan, 0.007), (16, 18, .cyan, 0.007), (18, 20, .cyan, 0.007),
            (18, 22, .cyan, 0.007), (20, 22, .cyan, 0.007),
            // 左臂
            (13, 15, .cyan, 0.007), (15, 17, .cyan, 0.007), (17, 19, .cyan, 0.007),
            (17, 21, .cyan, 0.007), (19, 21, .cyan, 0.007),
            // 右腿
            (12, 24, .yellow, 0.007), (24, 26, .yellow, 0.007),
            (26, 28, .yellow, 0.007), (28, 30, .yellow, 0.007),
            (28, 32, .yellow, 0.007), (30, 32, .yellow, 0.007),
            // 左腿
            (11, 23, .yellow, 0.007), (23, 25, .yellow, 0.007),
            (25, 27, .yellow, 0.007), (27, 29, .yellow, 0.007),
            (27, 31, .yellow, 0.007), (29, 31, .yellow, 0.007),
            // 髋连接
            (23, 24, .green, 0.008), (11, 23, .green, 0.008), (12, 24, .green, 0.008)
        ]
        for (a,b,color,r) in pairs {
            guard let pa = simdForJoint(joints, raw: a),
                  let pb = simdForJoint(joints, raw: b) else { continue }
            let edge = makeLine(from: pa, to: pb, color: color, thickness: r)
            bodyAnchor.addChild(edge)
            bodyEdges.append(edge)
        }
    }

    func simdForJoint(_ joints: [VNJointName3D: VNPoint3D], raw: Int) -> simd_float3? {
        let name = VNJointName3D(rawValue: raw)
        guard let j = joints[name] else { return nil }
        return simd_float3(x: j.location.x, y: j.location.y, z: j.location.z)
    }

    func clearBody() { bodyAnchor.isEnabled = false }
    func makeJoint(color: UIColor, radius: Float) -> ModelEntity {
        let sphere = MeshResource.generateSphere(radius: radius)
        let mat = SimpleMaterial(color: color, roughness: 0.1, isMetallic: false)
        let e = ModelEntity(mesh: sphere, materials: [mat])
        e.isEnabled = true
        return e
    }
    func makeLine(from a: simd_float3, to b: simd_float3, color: UIColor, thickness: Float) -> Entity {
        // RealityKit 没有直接的 generateLine,用细长 box 模拟
        let delta = b - a
        let len = simd_length(delta)
        let mid = a + delta * 0.5
        let box = MeshResource.generateBox(size: [thickness, thickness, len])
        let mat = SimpleMaterial(color: color, roughness: 0.1, isMetallic: false)
        let e = ModelEntity(mesh: box, materials: [mat])
        e.position = mid
        // 旋转 box 的 z 轴到 delta 方向
        let dir = simd_normalize(delta)
        let up = simd_float3(0, 0, 1)
        let q = simd_quatf(from: up, to: dir)
        e.transform.rotation = q
        return e
    }
}

// MARK: - 手部 (21 点 / 手)
extension ARController {
    func updateHand(from hand: VNRecognizedPoints3D, isLeft: Bool, frame: ARFrame) {
        guard let joints = try? hand.recognizedPoints(.all) else {
            clearHand(isLeft: isLeft); return
        }
        let anchor = isLeft ? leftHandAnchor : rightHandAnchor
        let keyPrefix = isLeft ? 100 : 200  // 区分左右手 joint id
        let color: UIColor = isLeft ? .orange : .pink

        for (rawIdx, rawPt) in joints {
            let idx = rawIdx.rawValue
            guard let pt = rawPt.location else { continue }
            let pos = simd_float3(x: pt.x, y: pt.y, z: pt.z)
            let key = keyPrefix + idx
            let node = handJoints[key] ?? makeJoint(color: color, radius: 0.008)
            node.position = pos
            if handJoints[key] == nil {
                anchor.addChild(node); handJoints[key] = node
            }
        }

        // 拓扑对 (掌心 0 → 手指 1-4, 每根手指 1 个关键点)
        // HandPose 在 iOS 15+ 返回 11 个关键点 (wrist + 5 手指 base), 21 个点需要 iOS 17+ 或扩展
        // 这里兼容用简化拓扑
        let pairs: [(Int,Int)] = [
            (0,1),(1,2),(2,3),(3,4),   // 拇指
            (0,5),(5,6),(6,7),(7,8),   // 食指
            (0,9),(9,10),(10,11),(11,12),   // 中指
            (0,13),(13,14),(14,15),(15,16), // 无名指
            (0,17),(17,18),(18,19),(19,20), // 小指
            (5,17),(5,9),(9,13),(13,17)     // 掌弓
        ]
        // 清旧线 (按左右手过滤)
        handEdges = handEdges.filter { e in anchor.children.contains(e) == false }
        for (a,b) in pairs {
            guard let pa = simdForJoint(joints, raw: a),
                  let pb = simdForJoint(joints, raw: b) else { continue }
            let edge = makeLine(from: pa, to: pb, color: color, thickness: 0.004)
            anchor.addChild(edge)
            handEdges.append(edge)
        }
        anchor.isEnabled = true
    }
    func clearHand(isLeft: Bool) {
        let anchor = isLeft ? leftHandAnchor : rightHandAnchor
        anchor.isEnabled = false
    }
}

// MARK: - 面部网格 (468 点)
extension ARController {
    func updateFace(from face: VNFaceObservation, frame: ARFrame) {
        // Vision 返回的是屏幕空间归一化坐标 (0...1), 需要反投影到 3D
        // 这里用简化方案: 取 face.boundingBox 的 center, 通过 ARRay 反投影到有深度的平面
        let bb = face.boundingBox
        let cx = (bb.minX + bb.maxX) * 0.5
        let cy = (bb.minY + bb.maxY) * 0.5
        // VNFaceLandmarks2D 返回各区域的点数组
        // 把所有点拼成 mesh 太复杂, 这里只画关键点 + 头部中心 3D 点
        guard let landmarks = face.landmarks else { clearFace(); return }
        lastFaceConfidence = face.confidence

        // 用 faceObservation 的 transform 4x4 矩阵 (iOS 14+) 拿到头部 3D pose
        if let faceTransform = face.faceTransform {
            // faceTransform 是 4x4 matrix_float4x4, 头部中心在相机坐标系
            let center = faceTransform.columns.3
            let headPos = simd_float3(x: center.x, y: center.y, z: center.z)
            let node = faceJoints[0] ?? makeJoint(color: .purple, radius: 0.03)
            node.position = headPos
            if faceJoints[0] == nil { faceAnchor.addChild(node); faceJoints[0] = node }
            faceAnchor.isEnabled = true
        } else {
            clearFace()
        }
    }
    func clearFace() { faceAnchor.isEnabled = false }
    func clearAllAnchors() {
        clearBody(); clearHand(isLeft: true); clearHand(isLeft: false); clearFace()
    }
}
