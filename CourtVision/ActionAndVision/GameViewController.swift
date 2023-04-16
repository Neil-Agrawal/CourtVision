import UIKit
import AVFoundation
import Vision

class GameViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    @IBOutlet weak var scoreLabel: UILabel!
    @IBOutlet var beanBags: [UIImageView]!
    @IBOutlet weak var gameStatusLabel: OverlayLabel!
    @IBOutlet weak var releaseAngleLabel: UILabel!
    @IBOutlet weak var metricsStackView: UIStackView!
    @IBOutlet weak var speedLabel: UILabel!
    @IBOutlet weak var speedStackView: UIStackView!
    @IBOutlet weak var throwTypeImage: UIImageView!
    @IBOutlet weak var dashboardView: DashboardView!
    @IBOutlet weak var underhandThrowView: ProgressView!
    @IBOutlet weak var overhandThrowView: ProgressView!
    @IBOutlet weak var underlegThrowView: ProgressView!
    private let gameManager = GameManager.shared
    private let detectPlayerRequest = VNDetectHumanBodyPoseRequest()
    private var playerDetected = false
    private var isBagInTargetRegion = false
    private var throwRegion = CGRect.null
    private var targetRegion = CGRect.null
    private let trajectoryView = TrajectoryView()
    private let playerBoundingBox = BoundingBoxView()
    private let jointSegmentView = JointSegmentView()
    private var noObservationFrameCount = 0
    private var trajectoryInFlightPoseObservations = 0
    private var showSummaryGesture: UITapGestureRecognizer!
    var scoreArr = [1,0,0,0,0]
    private let trajectoryQueue = DispatchQueue(label: "com.ActionAndVision.trajectory", qos: .userInteractive)
    private let bodyPoseDetectionMinConfidence: VNConfidence = 0.7
    private let trajectoryDetectionMinConfidence: VNConfidence = 0.5
    private let bodyPoseRecognizedPointMinConfidence: VNConfidence = 0.1
    private lazy var detectTrajectoryRequest: VNDetectTrajectoriesRequest! =
                        VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: GameConstants.trajectoryLength)

    var lastThrowMetrics: ThrowMetrics {
        get {
            return gameManager.lastThrowMetrics
        }
        set {
            gameManager.lastThrowMetrics = newValue
        }
    }

    var playerStats: PlayerStats {
        get {
            return gameManager.playerStats
        }
        set {
            gameManager.playerStats = newValue
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUIElements()
        showSummaryGesture = UITapGestureRecognizer(target: self, action: #selector(handleShowSummaryGesture(_:)))
        showSummaryGesture.numberOfTapsRequired = 2
        view.addGestureRecognizer(showSummaryGesture)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        gameStatusLabel.perform(transition: .fadeIn, duration: 0.12)
        gameStatusLabel.perform(transition: .fadeIn, duration: 0.12)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        detectTrajectoryRequest = nil
    }

    func getScoreLabelAttributedStringForScore(_ score: Int) -> NSAttributedString {
        let totalScore = NSMutableAttributedString(string: "Total Score ", attributes: [.foregroundColor: #colorLiteral(red: 1, green: 1, blue: 1, alpha: 0.65)])
        totalScore.append(NSAttributedString(string: "\(score)", attributes: [.foregroundColor: #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)]))
        totalScore.append(NSAttributedString(string: "/5", attributes: [.foregroundColor: #colorLiteral(red: 1, green: 1, blue: 1, alpha: 0.65)]))
        return totalScore
    }

    func setUIElements() {
        resetKPILabels()
        playerBoundingBox.borderColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)
        playerBoundingBox.backgroundOpacity = 0
        playerBoundingBox.isHidden = true
        view.addSubview(playerBoundingBox)
        view.addSubview(jointSegmentView)
        view.addSubview(trajectoryView)
        gameStatusLabel.text = "Waiting for player"
        underhandThrowView.throwType = .underhand
        overhandThrowView.throwType = .overhand
        underlegThrowView.throwType = .underleg
        scoreLabel.attributedText = getScoreLabelAttributedStringForScore(0)
    }

    func resetKPILabels() {
        dashboardView.speed = 0
        throwTypeImage.image = nil
        dashboardView.isHidden = true
        speedStackView.isHidden = true
        metricsStackView.isHidden = true
        underhandThrowView.isHidden = true
        overhandThrowView.isHidden = true
        underlegThrowView.isHidden = true
    }

    func updateKPILabels() {
        dashboardView.isHidden = false
        speedStackView.isHidden = false
        metricsStackView.isHidden = false
        
        underhandThrowView.isHidden = true
        overhandThrowView.isHidden = true
        underlegThrowView.isHidden = true
        speedLabel.text = "\(lastThrowMetrics.releaseSpeed)"
        releaseAngleLabel.text = "\(lastThrowMetrics.releaseAngle)°"
        scoreLabel.attributedText = getScoreLabelAttributedStringForScore(gameManager.playerStats.totalScore)
        throwTypeImage.image = UIImage(named: lastThrowMetrics.throwType.rawValue)
        switch lastThrowMetrics.throwType {
        case .overhand:
            overhandThrowView.incrementThrowCount()
        case .underhand:
            underhandThrowView.incrementThrowCount()
        case .underleg:
            underlegThrowView.incrementThrowCount()
        default:
            break
        }
        let beanBagView = beanBags[playerStats.throwCount - 1]
        beanBagView.image = UIImage(named: "Score\(lastThrowMetrics.score.rawValue)")
    }

    func updateBoundingBox(_ boundingBox: BoundingBoxView, withRect rect: CGRect?) {
        boundingBox.frame = rect ?? .zero
        boundingBox.perform(transition: (rect == nil ? .fadeOut : .fadeIn), duration: 0.1)
    }

    func humanBoundingBox(for observation: VNHumanBodyPoseObservation) -> CGRect {
        var box = CGRect.zero
        var normalizedBoundingBox = CGRect.null
        guard observation.confidence > bodyPoseDetectionMinConfidence, let points = try? observation.recognizedPoints(forGroupKey: .all) else {
            return box
        }
        for (_, point) in points where point.confidence > bodyPoseRecognizedPointMinConfidence {
            normalizedBoundingBox = normalizedBoundingBox.union(CGRect(origin: point.location, size: .zero))
        }
        if !normalizedBoundingBox.isNull {
            box = normalizedBoundingBox
        }
        let joints = getBodyJointsFor(observation: observation)
        DispatchQueue.main.async {
            self.jointSegmentView.joints = joints
        }
        if gameManager.stateMachine.currentState is GameManager.TrackThrowsState {
            playerStats.storeObservation(observation)
            if trajectoryView.inFlight {
                trajectoryInFlightPoseObservations += 1
            }
        }
        return box
    }
    func resetTrajectoryRegions() {
        let boardRegion = gameManager.boardRegion
        let playerRegion = playerBoundingBox.frame
        let throwWindowXBuffer: CGFloat = 100
        let throwWindowYBuffer: CGFloat = 100
        let targetWindowXBuffer: CGFloat = 50
        let throwRegionWidth: CGFloat = 400
        throwRegion = CGRect(x: playerRegion.maxX + throwWindowXBuffer, y: 0, width: throwRegionWidth, height: playerRegion.maxY - throwWindowYBuffer)
        targetRegion = CGRect(x: boardRegion.minX - targetWindowXBuffer, y: 0,
                              width: boardRegion.width + 2 * targetWindowXBuffer, height: boardRegion.maxY)
    }
    func updateTrajectoryRegions() {
        let trajectoryLocation = trajectoryView.fullTrajectory.currentPoint
        let didBagCrossCenterOfThrowRegion = trajectoryLocation.x > throwRegion.origin.x + throwRegion.width / 2
        guard !(throwRegion.contains(trajectoryLocation) && didBagCrossCenterOfThrowRegion) else {
            return
        }
        let overlapWindowBuffer: CGFloat = 50
        if targetRegion.contains(trajectoryLocation) {
        } else if trajectoryLocation.x + throwRegion.width / 2 - overlapWindowBuffer < targetRegion.origin.x {
            throwRegion.origin.x = trajectoryLocation.x - throwRegion.width / 2
        }
        trajectoryView.roi = throwRegion
    }
    
    func processTrajectoryObservations(_ controller: CameraViewController, _ results: [VNTrajectoryObservation]) {
        if self.trajectoryView.inFlight && results.count < 1 {
            self.noObservationFrameCount += 1
            if self.noObservationFrameCount > GameConstants.noObservationFrameLimit {
                self.updatePlayerStats(controller)
            }
        } else {
            for path in results where path.confidence > trajectoryDetectionMinConfidence {
                self.trajectoryView.duration = path.timeRange.duration.seconds
                self.trajectoryView.points = path.detectedPoints
                self.trajectoryView.perform(transition: .fadeIn, duration: 0.25)
                if !self.trajectoryView.fullTrajectory.isEmpty {
                    if !self.dashboardView.isHidden {
                        self.resetKPILabels()
                    }
                    self.updateTrajectoryRegions()
                    if self.trajectoryView.isThrowComplete {
                        self.updatePlayerStats(controller)
                    }
                }
                self.noObservationFrameCount = 0
            }
        }
    }
    
    func updatePlayerStats(_ controller: CameraViewController) {
        let finalBagLocation = trajectoryView.finalBagLocation
        playerStats.storePath(self.trajectoryView.fullTrajectory.cgPath)
        trajectoryView.resetPath()
        lastThrowMetrics.updateThrowType(playerStats.getLastThrowType())
        let score = computeScore(controller.viewPointForVisionPoint(finalBagLocation))
        let releaseSpeed = round(trajectoryView.speed * gameManager.pointToMeterMultiplier * 2.24 * 100 / 27) / 100
        let releaseAngle = playerStats.getReleaseAngle()
        lastThrowMetrics.updateMetrics(newScore: score, speed: releaseSpeed, angle: releaseAngle)
        self.gameManager.stateMachine.enter(GameManager.ThrowCompletedState.self)
    }
    
    func computeScore(_ finalBagLocation: CGPoint) -> Scoring {
        let heightBuffer: CGFloat = 100
        let boardRegion = gameManager.boardRegion
        let extendedBoardRegion = CGRect(x: boardRegion.origin.x, y: boardRegion.origin.y - heightBuffer,
                                        width: boardRegion.width, height: boardRegion.height + heightBuffer)
        let holeRegion = gameManager.holeRegion
        let extendedHoleRegion = CGRect(x: holeRegion.origin.x, y: holeRegion.origin.y - heightBuffer,
                                        width: holeRegion.width, height: holeRegion.height + heightBuffer)
        if !extendedBoardRegion.contains(finalBagLocation) {
            return Scoring.zero
        } else if extendedHoleRegion.contains(finalBagLocation) {
            return lastThrowMetrics.throwType == .underleg ? Scoring.fifteen : Scoring.three
        } else {
            return lastThrowMetrics.throwType == .underleg ? Scoring.five : Scoring.one
        }
    }
}

extension GameViewController: GameStateChangeObserver {
    func gameManagerDidEnter(state: GameManager.State, from previousState: GameManager.State?) {
        switch state {
        case is GameManager.DetectedPlayerState:
            playerDetected = true
            playerStats.reset()
            playerBoundingBox.perform(transition: .fadeOut, duration: 1.0)
            gameStatusLabel.text = "Go"
            gameStatusLabel.perform(transitions: [.popUp, .popOut], durations: [0.25, 0.12], delayBetween: 0) {
                self.gameManager.stateMachine.enter(GameManager.TrackThrowsState.self)
            }
        case is GameManager.TrackThrowsState:
            resetTrajectoryRegions()
            trajectoryView.roi = throwRegion
        case is GameManager.ThrowCompletedState:
            dashboardView.speed = lastThrowMetrics.releaseSpeed
            dashboardView.animateSpeedChart()
            playerStats.adjustMetrics(score: lastThrowMetrics.score, speed: lastThrowMetrics.releaseSpeed,
                                      releaseAngle: lastThrowMetrics.releaseAngle, throwType: lastThrowMetrics.throwType)
            playerStats.resetObservations()
            trajectoryInFlightPoseObservations = 0
            self.updateKPILabels()
            
            gameStatusLabel.text = lastThrowMetrics.score.rawValue > 0 ? "+\(lastThrowMetrics.score.rawValue)" : ""
            gameStatusLabel.perform(transitions: [.popUp, .popOut], durations: [0.12, 0.12], delayBetween: 0.5) {
                if self.playerStats.throwCount == GameConstants.maxThrows {
                    self.gameManager.stateMachine.enter(GameManager.ShowSummaryState.self)
                } else {
                    self.gameManager.stateMachine.enter(GameManager.TrackThrowsState.self)
                }
            }
        default:
            break
        }
    }
}

extension GameViewController: CameraViewControllerOutputDelegate {
    func cameraViewController(_ controller: CameraViewController, didReceiveBuffer buffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        let visionHandler = VNImageRequestHandler(cmSampleBuffer: buffer, orientation: orientation, options: [:])
        if gameManager.stateMachine.currentState is GameManager.TrackThrowsState {
            DispatchQueue.main.async {
                let normalizedFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
                self.jointSegmentView.frame = controller.viewRectForVisionRect(normalizedFrame)
                self.trajectoryView.frame = controller.viewRectForVisionRect(normalizedFrame)
            }
            trajectoryQueue.async {
                do {
                    try visionHandler.perform([self.detectTrajectoryRequest])
                    if let results = self.detectTrajectoryRequest.results {
                        DispatchQueue.main.async {
                            self.processTrajectoryObservations(controller, results)
                        }
                    }
                } catch {
                    AppError.display(error, inViewController: self)
                }
            }
        }
        if !(self.trajectoryView.inFlight && self.trajectoryInFlightPoseObservations >= GameConstants.maxTrajectoryInFlightPoseObservations) {
            do {
                try visionHandler.perform([detectPlayerRequest])
                if let result = detectPlayerRequest.results?.first {
                    let box = humanBoundingBox(for: result)
                    let boxView = playerBoundingBox
                    DispatchQueue.main.async {
                        let inset: CGFloat = -20.0
                        let viewRect = controller.viewRectForVisionRect(box).insetBy(dx: inset, dy: inset)
                        self.updateBoundingBox(boxView, withRect: viewRect)
                        if !self.playerDetected && !boxView.isHidden {
                            self.gameStatusLabel.alpha = 0
                            self.resetTrajectoryRegions()
                            self.gameManager.stateMachine.enter(GameManager.DetectedPlayerState.self)
                        }
                    }
                }
            } catch {
                AppError.display(error, inViewController: self)
            }
        } else {
            DispatchQueue.main.async {
                if !self.playerBoundingBox.isHidden {
                    self.playerBoundingBox.isHidden = true
                    self.jointSegmentView.resetView()
                }
            }
        }
    }
}

extension GameViewController {
    @objc
    func handleShowSummaryGesture(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended {
            self.gameManager.stateMachine.enter(GameManager.ShowSummaryState.self)
        }
    }
}
