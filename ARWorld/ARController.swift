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
    private let visionQueue = DispatchQueue(label: "com.arworld.vision", qos: .userInitiated)

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

    // 3D 实体容器 (AnchorEntity 符合 HasAnchoring)
    private let bodyAnchor = AnchorEntity()
    private let leftHandAnchor = AnchorEntity()
    private let rightHandAnchor = AnchorEntity()
    private let faceAnchor = AnchorEntity()
    private let gridAnchor = AnchorEntity()
    private var gridEntities: [Entity] = []

    // 关节球缓存
    private var bodyJoints: [String: Entity] = [:]
    private var handJoints: [Int: Entity] = [:]
    private var faceJoints: [Int: Entity] = [:]

    private var lastFrameTime: CFTimeInterval = 0
    private var lastVisionFrame: CFTimeInterval = 0

    private init() {
        super.init()
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.environmentTexturing = .automatic
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
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

    func start() {}

    func resetTracking() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func setupGrid() {
        let step: Float = 1.0, extent: Float = 8.0
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

// MARK: - ARSessionDelegate
extension ARController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in self.handleFrame(frame) }
    }

    private func handleFrame(_ frame: ARFrame) {
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

        depthAvailable = frame.sceneDepth != nil

        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0, dt < 1 { fps = fps * 0.8 + (1/dt) * 0.2 }
        }
        lastFrameTime = now

        guard now - lastVisionFrame > 0.04 else { return }
        lastVisionFrame = now

        let args = (
            frame.capturedImage,
            frame.camera,
            frame.sceneDepth,
            isBodyEnabled, isHandsEnabled, isFaceEnabled
        )
        visionQueue.async { [weak self] in
            self?.runVisionOnBackground(args)
        }
    }
}

// MARK: - Vision 后台执行
extension ARController {
    private nonisolated func runVisionOnBackground(_ args: (CVPixelBuffer, ARCamera, ARDepthData?, Bool, Bool, Bool)) {
        let (pixelBuffer, camera, sceneDepth, isBody, isHands, isFace) = args
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])
        var requests: [VNRequest] = []

        var poseReq: VNDetectHumanBodyPoseRequest?
        var handReq: VNDetectHumanHandPoseRequest?
        var faceReq: VNDetectFaceLandmarksRequest?

        if isBody {
            let r = VNDetectHumanBodyPoseRequest()
            requests.append(r); poseReq = r
        }
        if isHands {
            let r = VNDetectHumanHandPoseRequest()
            r.maximumHandCount = 2
            requests.append(r); handReq = r
        }
        if isFace {
            let r = VNDetectFaceLandmarksRequest()
            requests.append(r); faceReq = r
        }
        guard !requests.isEmpty else {
            Task { @MainActor in self.clearAllAnchors() }
            return
        }
        do { try handler.perform(requests) }
        catch { Task { @MainActor in self.clearAllAnchors() }; return }

        let bodyResults = poseReq?.results ?? []
        let handResults = handReq?.results ?? []
        let faceResults = faceReq?.results ?? []

        Task { @MainActor in
            if isBody {
                if let obs = bodyResults.first { self.updateBody(from: obs, camera: camera, sceneDepth: sceneDepth) }
                else { self.clearBody() }
            } else { self.clearBody() }

            if isHands {
                self.lastHandCount = handResults.count
                if handResults.count >= 2 {
                    self.updateHand(from: handResults[0], isLeft: true, camera: camera, sceneDepth: sceneDepth)
                    self.updateHand(from: handResults[1], isLeft: false, camera: camera, sceneDepth: sceneDepth)
                } else if handResults.count == 1 {
                    self.updateHand(from: handResults[0], isLeft: true, camera: camera, sceneDepth: sceneDepth)
                    self.clearHand(isLeft: false)
                } else { self.clearHand(isLeft: true); self.clearHand(isLeft: false) }
            } else { self.clearHand(isLeft: true); self.clearHand(isLeft: false) }

            if isFace {
                if let obs = faceResults.first { self.updateFace(from: obs, camera: camera, sceneDepth: sceneDepth) }
                else { self.clearFace() }
            } else { self.clearFace() }

            self.gridAnchor.isEnabled = self.isGridEnabled
        }
    }
}

// MARK: - 身体 (2D 关键点 + 深度反投影)
extension ARController {
    func updateBody(from obs: VNHumanBodyPoseObservation, camera: ARCamera, sceneDepth: ARDepthData?) {
        var worldPoints: [String: SIMD3<Float>] = [:]
        var confs: [Float] = []
        for name in obs.availableJointNames {
            guard let pt = try? obs.recognizedPoint(name) else { continue }
            confs.append(pt.confidence)
            let nx = pt.location.x, ny = pt.location.y
            if let p = projectToWorld(nx: nx, ny: ny, camera: camera, sceneDepth: sceneDepth) {
                worldPoints[name.rawValue] = p
            }
        }
        lastBodyConfidence = Double(confs.min() ?? 0)
        guard !worldPoints.isEmpty else { clearBody(); return }

        for (key, pos) in worldPoints {
            let node = bodyJoints[key] ?? makeJoint(color: .green, radius: 0.015)
            node.position = pos
            if bodyJoints[key] == nil {
                bodyAnchor.addChild(node); bodyJoints[key] = node
            }
        }
        bodyAnchor.isEnabled = true
    }

    func clearBody() { bodyAnchor.isEnabled = false }

    func makeJoint(color: UIColor, radius: Float) -> ModelEntity {
        let sphere = MeshResource.generateSphere(radius: radius)
        let mat = SimpleMaterial(color: color, roughness: 0.1, isMetallic: false)
        return ModelEntity(mesh: sphere, materials: [mat])
    }
}

// MARK: - 手部 (21 点 / 手)
extension ARController {
    func updateHand(from obs: VNHumanHandPoseObservation, isLeft: Bool, camera: ARCamera, sceneDepth: ARDepthData?) {
        var worldPoints: [String: SIMD3<Float>] = [:]
        for name in obs.availableJointNames {
            guard let pt = try? obs.recognizedPoint(name) else { continue }
            if let p = projectToWorld(nx: pt.location.x, ny: pt.location.y, camera: camera, sceneDepth: sceneDepth) {
                worldPoints[name.rawValue] = p
            }
        }
        guard !worldPoints.isEmpty else { clearHand(isLeft: isLeft); return }

        let anchor = isLeft ? leftHandAnchor : rightHandAnchor
        let prefix = isLeft ? "L_" : "R_"
        let color: UIColor = isLeft ? .orange : .systemPink

        for (key, pos) in worldPoints {
            let k = prefix + key
            let node = handJoints[hash(k)] ?? makeJoint(color: color, radius: 0.008)
            node.position = pos
            if handJoints[hash(k)] == nil {
                anchor.addChild(node); handJoints[hash(k)] = node
            }
        }
        anchor.isEnabled = true
    }

    func clearHand(isLeft: Bool) {
        let anchor = isLeft ? leftHandAnchor : rightHandAnchor
        anchor.isEnabled = false
    }
}

// MARK: - 面部 (468 点)
extension ARController {
    func updateFace(from obs: VNFaceObservation, camera: ARCamera, sceneDepth: ARDepthData?) {
        lastFaceConfidence = Double(obs.confidence)
        guard let landmarks = obs.landmarks,
              let all = landmarks.allPoints,
              !all.normalizedPoints.isEmpty else { clearFace(); return }

        // 中心头部球
        let bb = obs.boundingBox
        let cx = (bb.minX + bb.maxX) * 0.5
        let cy = (bb.minY + bb.maxY) * 0.5
        let center3D = projectToWorld(nx: cx, ny: cy, camera: camera, sceneDepth: sceneDepth)

        if let c = center3D {
            let node = faceJoints[0] ?? makeJoint(color: .purple, radius: 0.03)
            node.position = c
            if faceJoints[0] == nil { faceAnchor.addChild(node); faceJoints[0] = node }
        }

        // 采样关键点画小点 (每 8 个取 1 个 ≈ 58 点)
        var idx = 1
        for (i, pt) in all.normalizedPoints.enumerated() {
            guard i % 8 == 0 else { continue }
            let p = projectToWorld(nx: CGFloat(pt.x), ny: CGFloat(pt.y), camera: camera, sceneDepth: sceneDepth)
            let p3D = p ?? (center3D ?? SIMD3<Float>(0,0,0))
            let node = faceJoints[idx] ?? makeJoint(color: .magenta, radius: 0.004)
            node.position = p3D
            if faceJoints[idx] == nil { faceAnchor.addChild(node); faceJoints[idx] = node }
            idx += 1
        }
        faceAnchor.isEnabled = true
    }

    func clearFace() { faceAnchor.isEnabled = false }
    func clearAllAnchors() {
        clearBody(); clearHand(isLeft: true); clearHand(isLeft: false); clearFace()
    }

    /// 归一化图像坐标 (原点左下) → AR 世界坐标
    func projectToWorld(nx: CGFloat, ny: CGFloat, camera: ARCamera, sceneDepth: ARDepthData?) -> SIMD3<Float>? {
        let intrinsics = camera.intrinsics
        let resolution = camera.imageResolution
        let px = Float(nx) * Float(resolution.width)
        let py = Float(1 - ny) * Float(resolution.height)

        var depth: Float = 1.0
        if let depthMap = sceneDepth?.depthMap {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(depthMap) {
                let w = CVPixelBufferGetWidth(depthMap)
                let h = CVPixelBufferGetHeight(depthMap)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
                let dx = min(max(Int(px / Float(resolution.width) * Float(w)), 0), w - 1)
                let dy = min(max(Int(py / Float(resolution.height) * Float(h)), 0), h - 1)
                let ptr = base.assumingMemoryBound(to: Float.self)
                depth = ptr.advanced(by: dy * (bytesPerRow / MemoryLayout<Float>.size) + dx).pointee
            }
        }
        if depth <= 0 || !depth.isFinite { return nil }

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx0 = intrinsics.columns.2.x
        let cy0 = intrinsics.columns.2.y
        let xCam = (px - cx0) / fx * depth
        let yCam = (py - cy0) / fy * depth

        let camPoint = SIMD4<Float>(xCam, yCam, depth, 1)
        let world = camera.transform * camPoint
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
