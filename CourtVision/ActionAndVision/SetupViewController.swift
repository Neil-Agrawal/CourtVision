import UIKit
import AVFoundation
import Vision

class SetupViewController: UIViewController {

    @IBOutlet var statusLabel: OverlayLabel!
 
    private let gameManager = GameManager.shared
    private let boardLocationGuide = BoundingBoxView()
    private let boardBoundingBox = BoundingBoxView()

    private var boardDetectionRequest: VNCoreMLRequest!
    private let boardDetectionMinConfidence: VNConfidence = 0.3
    
    enum SceneSetupStage {
        case detectingBoard
        case detectingBoardPlacement
        case detectingSceneStability
        case detectingBoardContours
        case setupComplete
    }

    private var setupStage = SceneSetupStage.detectingBoard
    
    enum SceneStabilityResult {
        case unknown
        case stable
        case unstable
    }
    
    private let sceneStabilityRequestHandler = VNSequenceRequestHandler()
    private let sceneStabilityRequiredHistoryLength = 15
    private var sceneStabilityHistoryPoints = [CGPoint]()
    private var previousSampleBuffer: CMSampleBuffer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        boardLocationGuide.borderColor = #colorLiteral(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        boardLocationGuide.borderWidth = 3
        boardLocationGuide.borderCornerRadius = 4
        boardLocationGuide.borderCornerSize = 30
        boardLocationGuide.backgroundOpacity = 0.25
        boardLocationGuide.isHidden = true
        view.addSubview(boardLocationGuide)
        boardBoundingBox.borderColor = #colorLiteral(red: 1, green: 0.5763723254, blue: 0, alpha: 1)
        boardBoundingBox.borderWidth = 2
        boardBoundingBox.borderCornerRadius = 4
        boardBoundingBox.borderCornerSize = 0
        boardBoundingBox.backgroundOpacity = 0.45
        boardBoundingBox.isHidden = true
        view.addSubview(boardBoundingBox)
        updateSetupState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do {
            // Create Vision request based on CoreML model
            let model = try VNCoreMLModel(for: GameBoardDetector(configuration: MLModelConfiguration()).model)
            boardDetectionRequest = VNCoreMLRequest(model: model)
            // Since board is close to the side of a landscape image,
            // we need to set crop and scale option to scaleFit.
            // By default vision request will run on centerCrop.
            boardDetectionRequest.imageCropAndScaleOption = .scaleFit
        } catch {
            let error = AppError.createRequestError(reason: "Could not create Vision request for board detector")
            AppError.display(error, inViewController: self)
        }
    }
    
    func updateBoundingBox(_ boundingBox: BoundingBoxView, withViewRect rect: CGRect?, visionRect: CGRect) {
        DispatchQueue.main.async {
            boundingBox.frame = rect ?? .zero
            boundingBox.visionRect = visionRect
            if rect == nil {
                boundingBox.perform(transition: .fadeOut, duration: 0.1)
            } else {
                boundingBox.perform(transition: .fadeIn, duration: 0.1)
            }
        }
    }
    
    func updateSetupState() {
        let boardBox = boardBoundingBox
        DispatchQueue.main.async {
            switch self.setupStage {
            case .detectingBoard:
                self.statusLabel.text = "Locating Hoop"
            case .detectingBoardPlacement:
                // Board placement guide is shown only when using camera feed.
                // Otherwise we always assume the board is placed correctly.
                var boxPlacedCorrectly = true
                if !self.boardLocationGuide.isHidden {
                    boxPlacedCorrectly = boardBox.containedInside(self.boardLocationGuide)
                }
                boardBox.borderColor = boxPlacedCorrectly ? #colorLiteral(red: 0.4641711116, green: 1, blue: 0, alpha: 1) : #colorLiteral(red: 1, green: 0.5763723254, blue: 0, alpha: 1)
                if boxPlacedCorrectly {
                    self.statusLabel.text = "Keep Device Stationary"
                    self.setupStage = .detectingSceneStability
                } else {
                    self.statusLabel.text = "Place Hoop into the Box"
                }
            case .detectingSceneStability:
                switch self.sceneStability {
                case .unknown:
                    break
                case .unstable:
                    self.previousSampleBuffer = nil
                    self.sceneStabilityHistoryPoints.removeAll()
                    self.setupStage = .detectingBoardPlacement
                case .stable:
                    self.setupStage = .detectingBoardContours
                }
            default:
                break
            }
        }
    }
    
    func analyzeBoardContours(_ contours: [VNContour]) -> (edgePath: CGPath, holePath: CGPath)? {
        let polyContours = contours.compactMap { (contour) -> VNContour? in
            guard let polyContour = try? contour.polygonApproximation(epsilon: 0.01),
                  polyContour.pointCount >= 3 else {
                return nil
            }
            return polyContour
        }
        guard let boardContour = polyContours.max(by: { $0.pointCount < $1.pointCount }) else {
            return nil
        }
        let contourPoints = boardContour.normalizedPoints.map { return CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let diagonalThreshold = CGFloat(0.02)
        var largestDiff = CGFloat(0.0)
        let boardPath = UIBezierPath()
        let countLessOne = contourPoints.count - 1
        for (point1, point2) in zip(contourPoints.prefix(countLessOne), contourPoints.suffix(countLessOne)) where
            min(point1.x, point2.x) < 0.5 && max(point1.x, point2.x) > 0.5 && point1.y >= 0.3 && point2.y >= 0.3 {
            let diffX = abs(point1.x - point2.x)
            let diffY = abs(point1.y - point2.y)
            guard diffX > diagonalThreshold && diffY > diagonalThreshold else {
                continue
            }
            if diffX + diffY > largestDiff {
                largestDiff = diffX + diffY
                boardPath.removeAllPoints()
                boardPath.move(to: point1)
                boardPath.addLine(to: point2)
            }
        }
        guard largestDiff > 0 else {
            return nil
        }
        var holePath: CGPath?
        for contour in polyContours where contour != boardContour {
            let normalizedPath = contour.normalizedPath
            let normalizedBox = normalizedPath.boundingBox
            if normalizedBox.minX >= 0.5 && normalizedBox.minY >= 0.5 {
                holePath = normalizedPath
                break
            }
        }
        guard let detectedHolePath = holePath else {
            return nil
        }
        
        return (boardPath.cgPath, detectedHolePath)
    }
    
    var sceneStability: SceneStabilityResult {
        guard sceneStabilityHistoryPoints.count > sceneStabilityRequiredHistoryLength else {
            return .unknown
        }
        var movingAverage = CGPoint.zero
        movingAverage.x = sceneStabilityHistoryPoints.map { $0.x }.reduce(.zero, +)
        movingAverage.y = sceneStabilityHistoryPoints.map { $0.y }.reduce(.zero, +)
        let distance = abs(movingAverage.x) + abs(movingAverage.y)
        return (distance < 10 ? .stable : .unstable)
    }
}

extension SetupViewController: CameraViewControllerOutputDelegate {
    func cameraViewController(_ controller: CameraViewController, didReceiveBuffer buffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        do {
            switch setupStage {
            case .setupComplete:
                return
            case .detectingSceneStability:
                try checkSceneStability(controller, buffer, orientation)
            case .detectingBoardContours:
                try detectBoardContours(controller, buffer, orientation)
            case .detectingBoard, .detectingBoardPlacement:
                try detectBoard(controller, buffer, orientation)
            }
            updateSetupState()
        } catch {
            AppError.display(error, inViewController: self)
        }
    }
    
    private func checkSceneStability(_ controller: CameraViewController, _ buffer: CMSampleBuffer, _ orientation: CGImagePropertyOrientation) throws {
        guard let previousBuffer = self.previousSampleBuffer else {
            self.previousSampleBuffer = buffer
            return
        }
        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCMSampleBuffer: buffer)
        try sceneStabilityRequestHandler.perform([registrationRequest], on: previousBuffer, orientation: orientation)
        self.previousSampleBuffer = buffer
        if let alignmentObservation = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation {
            let transform = alignmentObservation.alignmentTransform
            sceneStabilityHistoryPoints.append(CGPoint(x: transform.tx, y: transform.ty))
        }
    }

    fileprivate func detectBoard(_ controller: CameraViewController, _ buffer: CMSampleBuffer, _ orientation: CGImagePropertyOrientation) throws {
        let visionHandler = VNImageRequestHandler(cmSampleBuffer: buffer, orientation: orientation, options: [:])
        try visionHandler.perform([boardDetectionRequest])
        var rect: CGRect?
        var visionRect = CGRect.null
        if let results = boardDetectionRequest.results as? [VNDetectedObjectObservation] {
            let filteredResults = results.filter { $0.confidence > boardDetectionMinConfidence }
            if !filteredResults.isEmpty {
                visionRect = filteredResults[0].boundingBox
                rect = controller.viewRectForVisionRect(visionRect)
            }
        }
        if gameManager.recordedVideoSource == nil {
            let guideVisionRect = CGRect(x: 0.75, y: 0.3, width: 0.3, height: 0.60)
            let guideRect = controller.viewRectForVisionRect(guideVisionRect)
            updateBoundingBox(boardLocationGuide, withViewRect: guideRect, visionRect: guideVisionRect)
        }
        updateBoundingBox(boardBoundingBox, withViewRect: rect, visionRect: visionRect)
        self.setupStage = (rect == nil) ? .detectingBoard : .detectingBoardPlacement
    }
    
    private func detectBoardContours(_ controller: CameraViewController, _ buffer: CMSampleBuffer, _ orientation: CGImagePropertyOrientation) throws {
        let visionHandler = VNImageRequestHandler(cmSampleBuffer: buffer, orientation: orientation, options: [:])
        let contoursRequest = VNDetectContoursRequest()
        contoursRequest.contrastAdjustment = 2
        contoursRequest.regionOfInterest = boardBoundingBox.visionRect
        try visionHandler.perform([contoursRequest])
        if let result = contoursRequest.results?.first as? VNContoursObservation {
            guard let subpaths = analyzeBoardContours(result.topLevelContours) else {
                return
            }
            DispatchQueue.main.sync {
                self.gameManager.boardRegion = boardBoundingBox.frame
                let edgeNormalizedBB = subpaths.edgePath.boundingBox
                let edgeSize = CGSize(width: edgeNormalizedBB.width * boardBoundingBox.frame.width,
                                      height: edgeNormalizedBB.height * boardBoundingBox.frame.height)
                let boardLength = hypot(edgeSize.width, edgeSize.height)
                self.gameManager.pointToMeterMultiplier = GameConstants.boardLength / Double(boardLength)
                if let imageBuffer = CMSampleBufferGetImageBuffer(buffer) {
                    let imageData = CIImage(cvImageBuffer: imageBuffer).oriented(orientation)
                    self.gameManager.previewImage = UIImage(ciImage: imageData)
                }
                var holeRect = subpaths.holePath.boundingBox
                holeRect.origin.y = 1 - holeRect.origin.y - holeRect.height
                let boardRect = boardBoundingBox.visionRect
                let normalizedHoleRegion = CGRect(
                        x: boardRect.origin.x + holeRect.origin.x * boardRect.width,
                        y: boardRect.origin.y + holeRect.origin.y * boardRect.height,
                        width: holeRect.width * boardRect.width,
                        height: holeRect.height * boardRect.height)
                self.gameManager.holeRegion = controller.viewRectForVisionRect(normalizedHoleRegion)
                let highlightPath = UIBezierPath(cgPath: subpaths.edgePath)
                highlightPath.append(UIBezierPath(cgPath: subpaths.holePath))
                boardBoundingBox.visionPath = highlightPath.cgPath
                boardBoundingBox.borderColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 0.199807363)
                self.gameManager.stateMachine.enter(GameManager.DetectedBoardState.self)
            }
        }
    }
}

extension SetupViewController: GameStateChangeObserver {
    func gameManagerDidEnter(state: GameManager.State, from previousState: GameManager.State?) {
        switch state {
        case is GameManager.DetectedBoardState:
            setupStage =  .setupComplete
            statusLabel.text = "Hoop Detected"
            statusLabel.perform(transitions: [.popUp, .popOut], durations: [0.25, 0.12], delayBetween: 0.5) {
                self.gameManager.stateMachine.enter(GameManager.DetectingPlayerState.self)
            }
        default:
            break
        }
    }
}
