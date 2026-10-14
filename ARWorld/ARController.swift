import Foundation
import ARKit
import RealityKit
import Vision
import Combine
import UIKit

// MARK: - 共享控制器 (AR + Vision + 3D 渲染 协调者)
@MainActor
final class ARController: NSObject, ObservableObject {
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

    // 3D 实体容器 (每种骨骼一个锚点, AnchorEntity 符合 HasAnchoring)
    private let bodyAnchor = AnchorEntity()
    private let leftHandAnchor = AnchorEntity()
    private let rightHandAnchor = AnchorEntity()
    private let faceAnchor = AnchorEntity()
    private let gridAnchor = AnchorEntity()
    private var gridEntities: [Entity] = []

    // 上一帧时间戳 (FPS 计算 + 丢帧)
    private var lastFrameTime: CFTimeInterval = 0
    private var lastVisionFrame: CFTimeInterval = 0

    // 模型实体缓存 (避免每帧重新创建 mesh)
    private var bodyJoints: [String: Entity] = [:]
    private var bodyEdges: [Entity] = []
    private var handJoints: [Int: Entity] = [:]  // 双手用合并 key (hand * 100 + index)
    private var handEdges: [Entity] = []
    private var faceJoints: [Int: Entity] = [:]

    private override init() {
        super.init()
        // RealityKit ARView, 启用 LiDAR 深度
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        arView = ARView(frame: .zero,
                        cameraMode: .ar,
                        automaticallyConfigureSession: false)
        arSession = ARSession()
        arView.session = arSession
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])

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

    func resetTracking() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.environmentTexturing = .automatic
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
}

// MARK: - ARSessionDelegate (每帧驱动 Vision)
extension ARController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // 注意: 此回调由 ARSession 在其自身队列调用, 我们切到 MainActor 处理
        Task { @MainActor in
            self.handleFrame(frame)
        }
    }

    private func handleFrame(_ frame: ARFrame) {
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

        // 深度可用? (LiDAR)
        depthAvailable = frame.sceneDepth != nil

        // FPS
        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0, dt < 1 { fps = fps * 0.8 + (1/dt) * 0.2 }
        }
        lastFrameTime = now

        // 丢帧策略: 每 40ms 跑一次 Vision
        guard now - lastVisionFrame > 0.04 else { return }
        lastVisionFrame = now

        // 提取像素缓冲 + 相机参数, 送到后台队列跑 Vision
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera
        let sceneDepth = frame.sceneDepth
        let isBody = isBodyEnabled
        let isHands = isHandsEnabled
        let isFace = isFaceEnabled

        visionQueue.async { [weak self] in
            self?.runVisionOnBackground(pixelBuffer: pixelBuffer,
                                        camera: camera,
                                        sceneDepth: sceneDepth,
                                        isBody: isBody,
                                        isHands: isHands,
                                        isFace: isFace)
        }
    }
}

// MARK: - Vision 请求链 (Pose + Hand × 2 + FaceLandmarks) — 在后台队列执行
extension ARController {
    private nonisolated func runVisionOnBackground(pixelBuffer: CVPixelBuffer,
                                                   camera: ARCamera,
                                                   sceneDepth: ARDepthData?,
                                                   isBody: Bool, isHands: Bool, isFace: Bool) {
        let orientation = CGImagePropertyOrientation.right  // 后置摄像头竖屏
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])
        var requests: [VNRequest] = []

        var poseReq: VNDetectHumanBodyPoseRequest?
        var handReq: VNDetectHumanHandPoseRequest?
        var faceReq: VNDetectFaceLandmarksRequest?

        if isBody {
            let pose = VNDetectHumanBodyPoseRequest()
            requests.append(pose)
            poseReq = pose
        }
        if isHands {
            let hand = VNDetectHumanHandPoseRequest()
            hand.maximumHandCount = 2
            requests.append(hand)
            handReq = hand
        }
        if isFace {
            let face = VNDetectFaceLandmarksRequest()
            requests.append(face)
            faceReq = face
        }
        guard !requests.isEmpty else {
            Task { @MainActor in self.clearAllAnchors() }
            return
        }

        do {
            try handler.perform(requests)
        } catch {
            print("[Vision] error:", error)
            Task { @MainActor in self.clearAllAnchors() }
            return
        }

        // 解析结果, 切回主线程渲染
        let bodyResults = poseReq?.results ?? []
        let handResults = handReq?.results ?? []
        let faceResults = faceReq?.results ?? []

        Task { @MainActor in
            // body
            if isBody {
                if let obs = bodyResults.first {
                    self.updateBody(from: obs)
                } else {
                    self.clearBody()
                }
            } else {
                self.clearBody()
            }

            // hands
            if isHands {
                self.lastHandCount = handResults.count
                if handResults.count >= 2 {
                    self.updateHand(from: handResults[0], isLeft: true, camera: camera, sceneDepth: sceneDepth)
                    self.updateHand(from: handResults[1], isLeft: false, camera: camera, sceneDepth: sceneDepth)
                } else if handResults.count == 1 {
                    self.updateHand(from: handResults[0], isLeft: true, camera: camera, sceneDepth: sceneDepth)
                    self.clearHand(isLeft: false)
                } else {
                    self.clearHand(isLeft: true)
                    self.clearHand(isLeft: false)
                }
            } else {
                self.clearHand(isLeft: true); self.clearHand(isLeft: false)
            }

            // face
            if isFace {
                if let obs = faceResults.first {
                    self.updateFace(from: obs, camera: camera, sceneDepth: sceneDepth)
                } else {
                    self.clearFace()
                }
            } else {
                self.clearFace()
            }

            self.gridAnchor.isEnabled = self.isGridEnabled
        }
    }
}

// MARK: - 身体骨骼
extension ARController {
    func updateBody(from observation: VNHumanBodyPoseObservation) {
        guard #available(iOS 17.0, *) else { clearBody(); return }
        // Vision 3D 关键点 (ARWorld 坐标系)
        let joints3D = observation.keypoints3D
        guard !joints3D.isEmpty else { clearBody(); return }

        // 转成 [String: VNRecognizedPoint3D] 便于按名称查找
        var byName: [String: VNRecognizedPoint3D] = [:]
        for (name, pt) in joints3D { byName[name.rawValue] = pt }

        lastBodyConfidence = Double(joints3D.values.compactMap { $0.confidence }.min() ?? 0)

        // 画关节
        for (name, pt) in joints3D {
            guard let loc = pt.location else { continue }
            let key = name.rawValue
            let worldPos = SIMD3<Float>(Float(loc.x), Float(loc.y), Float(loc.z))
            let node = bodyJoints[key] ?? makeJoint(color: .green, radius: 0.015)
            node.position = worldPos
            if bodyJoints[key] == nil {
                bodyAnchor.addChild(node); bodyJoints[key] = node
            }
        }
        drawBodyEdges(byName)
        bodyAnchor.isEnabled = true
    }

    // 身体拓扑对 (用 JointName 的 rawValue 字符串)
    func drawBodyEdges(_ joints: [String: VNRecognizedPoint3D]) {
        bodyEdges.forEach { bodyAnchor.removeChild($0) }
        bodyEdges.removeAll()

        let pairs: [(String, String, UIColor, Float)] = [
            // 躯干
            ("center", "neck", .green, 0.008),
            ("neck", "right_shoulder", .green, 0.008),
            ("neck", "left_shoulder", .green, 0.008),
            ("right_shoulder", "right_hip", .green, 0.008),
            ("left_shoulder", "left_hip", .green, 0.008),
            ("right_hip", "left_hip", .green, 0.008),
            // 右臂
            ("right_shoulder", "right_elbow", .cyan, 0.007),
            ("right_elbow", "right_wrist", .cyan, 0.007),
            // 左臂
            ("left_shoulder", "left_elbow", .cyan, 0.007),
            ("left_elbow", "left_wrist", .cyan, 0.007),
            // 右腿
            ("right_hip", "right_knee", .yellow, 0.007),
            ("right_knee", "right_ankle", .yellow, 0.007),
            // 左腿
            ("left_hip", "left_knee", .yellow, 0.007),
            ("left_knee", "left_ankle", .yellow, 0.007),
            // 头
            ("neck", "top_head", .green, 0.008),
        ]
        for (a, b, color, r) in pairs {
            guard let pa = simdForName(joints, name: a),
                  let pb = simdForName(joints, name: b) else { continue }
            let edge = makeLine(from: pa, to: pb, color: color, thickness: r)
            bodyAnchor.addChild(edge)
            bodyEdges.append(edge)
        }
    }

    func simdForName(_ joints: [String: VNRecognizedPoint3D], name: String) -> SIMD3<Float>? {
        guard let j = joints[name], let loc = j.location else { return nil }
        return SIMD3<Float>(Float(loc.x), Float(loc.y), Float(loc.z))
    }

    func clearBody() { bodyAnchor.isEnabled = false }

    func makeJoint(color: UIColor, radius: Float) -> ModelEntity {
        let sphere = MeshResource.generateSphere(radius: radius)
        let mat = SimpleMaterial(color: color, roughness: 0.1, isMetallic: false)
        let e = ModelEntity(mesh: sphere, materials: [mat])
        e.isEnabled = true
        return e
    }

    func makeLine(from a: SIMD3<Float>, to b: SIMD3<Float>, color: UIColor, thickness: Float) -> Entity {
        let delta = b - a
        let len = simd_length(delta)
        guard len > 0.0001 else { return Entity() }
        let mid = a + delta * 0.5
        let box = MeshResource.generateBox(size: [thickness, thickness, len])
        let mat = SimpleMaterial(color: color, roughness: 0.1, isMetallic: false)
        let e = ModelEntity(mesh: box, materials: [mat])
        e.position = mid
        let dir = simd_normalize(delta)
        let up = SIMD3<Float>(0, 0, 1)
        let q = simd_quatf(from: up, to: dir)
        e.transform.rotation = q
        return e
    }
}

// MARK: - 手部 (21 点 / 手)
extension ARController {
    func updateHand(from observation: VNHumanHandPoseObservation, isLeft: Bool, camera: ARCamera, sceneDepth: ARDepthData?) {
        guard #available(iOS 17.0, *) else { clearHand(isLeft: isLeft); return }
        let joints3D = observation.keypoints3D
        guard !joints3D.isEmpty else { clearHand(isLeft: isLeft); return }

        var byName: [String: VNRecognizedPoint3D] = [:]
        for (name, pt) in joints3D { byName[name.rawValue] = pt }

        let anchor = isLeft ? leftHandAnchor : rightHandAnchor
        let keyPrefix = isLeft ? 100 : 200
        let color: UIColor = isLeft ? .orange : .systemPink

        // 画关节
        var idx = 0
        for (_, pt) in joints3D {
            guard let loc = pt.location else { idx += 1; continue }
            let pos = SIMD3<Float>(Float(loc.x), Float(loc.y), Float(loc.z))
            let key = keyPrefix + idx
            let node = handJoints[key] ?? makeJoint(color: color, radius: 0.008)
            node.position = pos
            if handJoints[key] == nil {
                anchor.addChild(node); handJoints[key] = node
            }
            idx += 1
        }

        // 手部拓扑对 (按 3D joint name 字符串)
        let pairs: [(String, String)] = [
            ("wrist", "thumb_cmc"), ("thumb_cmc", "thumb_mcp"), ("thumb_mcp", "thumb_ip"), ("thumb_ip", "thumb_tip"),
            ("wrist", "index_mcp"), ("index_mcp", "index_pip"), ("index_pip", "index_dip"), ("index_dip", "index_tip"),
            ("wrist", "middle_mcp"), ("middle_mcp", "middle_pip"), ("middle_pip", "middle_dip"), ("middle_dip", "middle_tip"),
            ("wrist", "ring_mcp"), ("ring_mcp", "ring_pip"), ("ring_pip", "ring_dip"), ("ring_dip", "ring_tip"),
            ("wrist", "little_mcp"), ("little_mcp", "little_pip"), ("little_pip", "little_dip"), ("little_dip", "little_tip"),
            ("index_mcp", "middle_mcp"), ("middle_mcp", "ring_mcp"), ("ring_mcp", "little_mcp"),
        ]
        for (a, b) in pairs {
            guard let pa = simdForName(byName, name: a),
                  let pb = simdForName(byName, name: b) else { continue }
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

// MARK: - 面部网格
extension ARController {
    func updateFace(from observation: VNFaceObservation, camera: ARCamera, sceneDepth: ARDepthData?) {
        lastFaceConfidence = Double(observation.confidence)
        guard let landmarks = observation.landmarks else { clearFace(); return }

        // 取所有关键点 (468 个), 归一化坐标, 反投影到 3D
        guard let allPoints = landmarks.allPoints,
              let normalizedPoints = allPoints.normalizedPoints else { clearFace(); return }

        let bb = observation.boundingBox
        let cx = (bb.minX + bb.maxX) * 0.5
        let cy = (bb.minY + bb.maxY) * 0.5

        // 用中心深度做头部中心 3D 定位
        let center3D = projectToWorld(nx: cx, ny: cy, camera: camera, sceneDepth: sceneDepth)

        // 头部中心球
        if let c = center3D {
            let node = faceJoints[0] ?? makeJoint(color: .purple, radius: 0.03)
            node.position = c
            if faceJoints[0] == nil { faceAnchor.addChild(node); faceJoints[0] = node }
        }

        // 采样部分关键点画小点 (避免 468 个球太多, 每 8 个取 1 个)
        var sampleIdx = 1
        for (i, pt) in normalizedPoints.enumerated() {
            guard i % 8 == 0 else { continue }
            let p3D = projectToWorld(nx: CGFloat(pt.x), ny: CGFloat(pt.y), camera: camera, sceneDepth: sceneDepth) ?? (center3D ?? SIMD3<Float>(0,0,0))
            let node = faceJoints[sampleIdx] ?? makeJoint(color: .magenta, radius: 0.004)
            node.position = p3D
            if faceJoints[sampleIdx] == nil { faceAnchor.addChild(node); faceJoints[sampleIdx] = node }
            sampleIdx += 1
        }
        faceAnchor.isEnabled = true
    }

    /// 把归一化图像坐标 (0...1, 原点左下) 反投影到 AR 世界坐标
    func projectToWorld(nx: CGFloat, ny: CGFloat, camera: ARCamera, sceneDepth: ARDepthData?) -> SIMD3<Float>? {
        let intrinsics = camera.intrinsics
        let resolution = camera.imageResolution
        // 归一化 → 像素
        let px = nx * resolution.width
        let py = (1 - ny) * resolution.height  // Vision 坐标原点左下, 像素原点左上

        // 取深度
        var depth: Float = 1.0
        if let depthMap = sceneDepth?.depthMap {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(depthMap) {
                let w = CVPixelBufferGetWidth(depthMap)
                let h = CVPixelBufferGetHeight(depthMap)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
                let dx = min(max(Int(px / resolution.width * CGFloat(w)), 0), w - 1)
                let dy = min(max(Int(py / resolution.height * CGFloat(h)), 0), h - 1)
                let ptr = base.assumingMemoryBound(to: Float.self)
                depth = ptr.advanced(by: dy * (bytesPerRow / MemoryLayout<Float>.size) + dx).pointee
            }
        }

        // 反投影: 像素 → 相机坐标 → 世界坐标
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx0 = intrinsics.columns.2.x
        let cy0 = intrinsics.columns.2.y

        let xCam = (Float(px) - cx0) / fx * depth
        let yCam = (Float(py) - cy0) / fy * depth
        let zCam = depth

        let camPoint = SIMD4<Float>(xCam, yCam, zCam, 1)
        let worldPoint = camera.transform * camPoint
        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }

    func clearFace() { faceAnchor.isEnabled = false }
    func clearAllAnchors() {
        clearBody(); clearHand(isLeft: true); clearHand(isLeft: false); clearFace()
    }
}
