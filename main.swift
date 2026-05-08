import SwiftUI
import CoreMotion
import Speech
import AVFoundation
import AudioToolbox
import UserNotifications
import MessageUI
import Vision

// MARK: - SMS Composer
struct SMSComposer: UIViewControllerRepresentable {
    var recipients: [String]
    var message: String
    var onDismiss: () -> Void
    
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients.filter { !$0.isEmpty }
        vc.body = message
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
    
    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            onDismiss()
        }
    }
}

// MARK: - Camera Preview View
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
    
    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Eye Tracker
class EyeTracker: NSObject, ObservableObject {
    @Published var avgEyeX: CGFloat = 0.5
    @Published var faceDetected: Bool = false
    
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "eye.tracking.queue", qos: .userInteractive)
    private var lastFrameTime: TimeInterval = 0
    private var eyeXHistory: [CGFloat] = []
    
    override init() {
        super.init()
        setupCamera()
    }
    
    private func setupCamera() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )
        guard let device = session.devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .medium
        if captureSession.canAddInput(input) { captureSession.addInput(input) }
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        captureSession.commitConfiguration()
    }
    
    func start() { queue.async { self.captureSession.startRunning() } }
    func stop() { queue.async { self.captureSession.stopRunning() } }
}

extension EyeTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date().timeIntervalSince1970
        guard now - lastFrameTime > 0.15 else { return }
        lastFrameTime = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let request = VNDetectFaceLandmarksRequest { [weak self] req, _ in
            guard let self = self else { return }
            guard let results = req.results as? [VNFaceObservation],
                  let face = results.first,
                  let landmarks = face.landmarks else {
                DispatchQueue.main.async { self.faceDetected = false }
                return
            }
            
            var leftX: CGFloat = 0.5
            var rightX: CGFloat = 0.5
            
            if let leftEye = landmarks.leftEye, leftEye.pointCount > 0 {
                let pts = leftEye.normalizedPoints
                let cx = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
                leftX = face.boundingBox.origin.x + cx * face.boundingBox.width
            }
            if let rightEye = landmarks.rightEye, rightEye.pointCount > 0 {
                let pts = rightEye.normalizedPoints
                let cx = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
                rightX = face.boundingBox.origin.x + cx * face.boundingBox.width
            }
            
            let raw = (leftX + rightX) / 2.0
            self.eyeXHistory.append(raw)
            if self.eyeXHistory.count > 5 { self.eyeXHistory.removeFirst() }
            let smoothed = self.eyeXHistory.reduce(0, +) / CGFloat(self.eyeXHistory.count)
            
            DispatchQueue.main.async {
                self.faceDetected = true
                self.avgEyeX = smoothed
            }
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        try? handler.perform([request])
    }
}

// MARK: - Eyes Result
struct EyesResult: Equatable, Codable {
    var totalDots: Int
    var tappedDots: Int
    var leftMisses: Int
    var rightMisses: Int
    
    var accuracy: Double {
        totalDots == 0 ? 1.0 : Double(tappedDots) / Double(totalDots)
    }
    var hasHemianopia: Bool {
        let totalMisses = totalDots - tappedDots
        guard totalMisses >= 3 else { return false }
        let leftRatio = Double(leftMisses) / Double(max(totalMisses, 1))
        let rightRatio = Double(rightMisses) / Double(max(totalMisses, 1))
        return leftRatio > 0.7 || rightRatio > 0.7
    }
    var hasWarning: Bool { accuracy < 0.6 || hasHemianopia }
    var summaryText: String {
        if hasHemianopia { return (leftMisses > rightMisses ? "Left" : "Right") + " side vision issue" }
        return accuracy < 0.6 ? "Low tracking accuracy" : "Normal"
    }
}

// MARK: - App States
enum AppState: Equatable {
    case splash, onboarding, disclaimer, home, settings, history
    case intro(TestPhase)
    case testing(TestPhase)
    case results(leftTap: Int, rightTap: Int, leftArm: Double, rightArm: Double, balance: Double, speechScore: Double, eyesScore: EyesResult)
    
    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.splash, .splash), (.onboarding, .onboarding), (.disclaimer, .disclaimer),
            (.home, .home), (.settings, .settings), (.history, .history): return true
        case (.intro(let a), .intro(let b)): return a == b
        case (.testing(let a), .testing(let b)): return a == b
        case (.results, .results): return true
        default: return false
        }
    }
}

// MARK: - Test Phase
enum TestPhase: String, CaseIterable, Equatable {
    case tapLeft = "TL", tapRight = "TR"
    case armLeft = "AL", armRight = "AR"
    case balance = "BL"
    case speech1 = "S1", speech2 = "S2"
    case eyes = "ET"
    
    var title: String {
        switch self {
        case .tapLeft: return "TAP — Left Hand"
        case .tapRight: return "TAP — Right Hand"
        case .armLeft: return "ARM — Hold Left"
        case .armRight: return "ARM — Hold Right"
        case .balance: return "BALANCE — Stand Still"
        case .speech1: return "SPEAK — Sentence 1"
        case .speech2: return "SPEAK — Sentence 2"
        case .eyes: return "EYES — Follow the dot"
        }
    }
    
    var instruction: String {
        switch self {
        case .tapLeft: return "Tap the circles using\nonly your LEFT hand"
        case .tapRight: return "Tap the circles using\nonly your RIGHT hand"
        case .armLeft: return "Hold the phone flat\nin your LEFT palm\nwith arm extended"
        case .armRight: return "Hold the phone flat\nin your RIGHT palm\nwith arm extended"
        case .balance: return "Stand up straight\nHold phone against your chest\nStay as still as possible"
        case .speech1, .speech2: return "Read the sentence\nout loud clearly"
        case .eyes: return "Follow the dot with your EYES\nKeep your head still\nCamera will track your gaze"
        }
    }
    
    var icon: String {
        switch self {
        case .tapLeft: return "hand.point.left.fill"
        case .tapRight: return "hand.point.right.fill"
        case .armLeft, .armRight: return "figure.arms.open"
        case .balance: return "figure.stand"
        case .speech1, .speech2: return "mic.fill"
        case .eyes: return "eye.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .tapLeft: return .blue
        case .tapRight: return .orange
        case .armLeft: return .purple
        case .armRight: return .teal
        case .balance: return Color(red: 0.8, green: 0.4, blue: 0.1)
        case .speech1, .speech2: return .indigo
        case .eyes: return Color(red: 0.1, green: 0.6, blue: 0.4)
        }
    }
    
    var befastProgress: [Bool] {
        switch self {
        case .tapLeft:  return [true,  false, false, false, false, false, false, false]
        case .tapRight: return [true,  true,  false, false, false, false, false, false]
        case .armLeft:  return [true,  true,  true,  false, false, false, false, false]
        case .armRight: return [true,  true,  true,  true,  false, false, false, false]
        case .balance:  return [true,  true,  true,  true,  true,  false, false, false]
        case .speech1:  return [true,  true,  true,  true,  true,  true,  false, false]
        case .speech2:  return [true,  true,  true,  true,  true,  true,  true,  false]
        case .eyes:     return [true,  true,  true,  true,  true,  true,  true,  true ]
        }
    }
}

// MARK: - Test Result Model
struct TestResult: Identifiable, Codable {
    let id: UUID
    let date: Date
    let leftTap: Int, rightTap: Int
    let leftArm: Double, rightArm: Double
    let balanceScore: Double, speechScore: Double
    let eyesResult: EyesResult
    
    init(leftTap: Int, rightTap: Int, leftArm: Double, rightArm: Double,
         balanceScore: Double, speechScore: Double, eyesResult: EyesResult) {
        self.id = UUID(); self.date = Date()
        self.leftTap = leftTap; self.rightTap = rightTap
        self.leftArm = leftArm; self.rightArm = rightArm
        self.balanceScore = balanceScore; self.speechScore = speechScore
        self.eyesResult = eyesResult
    }
    
    var tapWarning: Bool { abs(leftTap - rightTap) >= 8 }
    var armWarning: Bool { leftArm >= 0.3 || rightArm >= 0.3 || abs(leftArm - rightArm) >= 0.3 }
    var balanceWarning: Bool { balanceScore >= 0.25 }
    var speechWarning: Bool { speechScore < 0.7 }
    var eyesWarning: Bool { eyesResult.hasWarning }
    var anyWarning: Bool { tapWarning || armWarning || balanceWarning || speechWarning || eyesWarning }
}

// MARK: - Reminder Manager
struct ReminderManager {
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
    }
    
    static func schedule(frequency: String) {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        let content = UNMutableNotificationContent()
        content.title = "BEFAST Check-in"
        content.body = "Time for your stroke screening test. It only takes 3 minutes."
        content.sound = .default
        var components = DateComponents()
        components.hour = 9; components.minute = 0
        if frequency == "weekly" { components.weekday = 2 }
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "befast_reminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    static func cancel() { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
}

// MARK: - Data Store
class AppDataStore: ObservableObject {
    @Published var hasAcceptedDisclaimer: Bool { didSet { UserDefaults.standard.set(hasAcceptedDisclaimer, forKey: "disclaimerAccepted") } }
    @Published var hasCompletedOnboarding: Bool { didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "onboardingComplete") } }
    @Published var emergencyContact1: String { didSet { UserDefaults.standard.set(emergencyContact1, forKey: "emergencyContact1") } }
    @Published var emergencyContact2: String { didSet { UserDefaults.standard.set(emergencyContact2, forKey: "emergencyContact2") } }
    @Published var emergencyNumber: String { didSet { UserDefaults.standard.set(emergencyNumber, forKey: "emergencyNumber") } }
    @Published var reminderEnabled: Bool {
        didSet {
            UserDefaults.standard.set(reminderEnabled, forKey: "reminderEnabled")
            reminderEnabled ? ReminderManager.schedule(frequency: reminderFrequency) : ReminderManager.cancel()
        }
    }
    @Published var reminderFrequency: String {
        didSet {
            UserDefaults.standard.set(reminderFrequency, forKey: "reminderFrequency")
            if reminderEnabled { ReminderManager.schedule(frequency: reminderFrequency) }
        }
    }
    @Published var testResults: [TestResult] { didSet { saveResults() } }
    
    init() {
        self.hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: "disclaimerAccepted")
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboardingComplete")
        self.emergencyContact1 = UserDefaults.standard.string(forKey: "emergencyContact1") ?? ""
        self.emergencyContact2 = UserDefaults.standard.string(forKey: "emergencyContact2") ?? ""
        self.emergencyNumber = UserDefaults.standard.string(forKey: "emergencyNumber") ?? "112"
        self.reminderEnabled = UserDefaults.standard.bool(forKey: "reminderEnabled")
        self.reminderFrequency = UserDefaults.standard.string(forKey: "reminderFrequency") ?? "weekly"
        if let data = UserDefaults.standard.data(forKey: "testResults"),
           let decoded = try? JSONDecoder().decode([TestResult].self, from: data) {
            self.testResults = decoded
        } else { self.testResults = [] }
    }
    
    func saveResults() {
        if let encoded = try? JSONEncoder().encode(testResults) {
            UserDefaults.standard.set(encoded, forKey: "testResults")
        }
    }
    
    func addResult(_ result: TestResult) { testResults.insert(result, at: 0) }
}

// MARK: - Orientation Manager
// OPTIMIZED: Added deinit to remove observer and prevent memory leak
class OrientationManager: ObservableObject {
    @Published var isLandscape: Bool = false
    
    init() {
        update()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(orientationChanged),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func orientationChanged() { update() }
    
    func update() {
        let o = UIDevice.current.orientation
        if o == .landscapeLeft || o == .landscapeRight {
            DispatchQueue.main.async { self.isLandscape = true }
        } else if o == .portrait || o == .portraitUpsideDown {
            DispatchQueue.main.async { self.isLandscape = false }
        }
    }
}

// MARK: - Portrait Lock Overlay
struct PortraitLockOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 28) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.1)).frame(width: 120, height: 120)
                    Image(systemName: "rotate.left").font(.system(size: 52)).foregroundColor(.white)
                }
                VStack(spacing: 10) {
                    Text("Portrait Mode Required").font(.title2.bold()).foregroundColor(.white).multilineTextAlignment(.center)
                    Text("Please rotate your device\nto portrait mode to continue.")
                        .font(.body).foregroundColor(.white.opacity(0.7)).multilineTextAlignment(.center)
                }
            }.padding(40)
        }
    }
}

// MARK: - Shared Countdown Progress Bar
// OPTIMIZED: Extracted reusable component used across all test views
struct CountdownProgressBar: View {
    let value: Double
    let total: Double
    let color: Color
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.2)).frame(height: 10)
                RoundedRectangle(cornerRadius: 8).fill(color)
                    .frame(width: geo.size.width * CGFloat(value / total), height: 10)
                    .animation(.linear(duration: 0.1), value: value)
            }
        }
        .frame(height: 10)
        .padding(.horizontal, 30)
    }
}

// MARK: - Main App Entry
struct ContentView: View {
    @StateObject private var store = AppDataStore()
    @StateObject private var orientation = OrientationManager()
    @State private var appState: AppState = .splash
    @State private var leftTapScore = 0
    @State private var rightTapScore = 0
    @State private var leftArmScore = 0.0
    @State private var rightArmScore = 0.0
    @State private var balanceScore = 0.0
    @State private var speechScores: [Double] = []
    @State private var goingForward = true
    
    var body: some View {
        ZStack {
            currentView
                .transition(goingForward
                            ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
                            : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
                )
            if orientation.isLandscape {
                PortraitLockOverlay()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: orientation.isLandscape)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appState)
    }
    
    func navigate(to state: AppState, forward: Bool = true) {
        goingForward = forward
        withAnimation { appState = state }
    }
    
    @ViewBuilder
    var currentView: some View {
        switch appState {
        case .splash:
            SplashView {
                if !store.hasCompletedOnboarding { navigate(to: .onboarding) }
                else if !store.hasAcceptedDisclaimer { navigate(to: .disclaimer) }
                else { navigate(to: .home) }
            }
        case .onboarding:
            OnboardingView { store.hasCompletedOnboarding = true; navigate(to: .disclaimer) }
        case .disclaimer:
            DisclaimerView { store.hasAcceptedDisclaimer = true; navigate(to: .home) }
        case .home:
            HomeView(
                onStart: { speechScores = []; navigate(to: .intro(.tapLeft)) },
                onSettings: { navigate(to: .settings) },
                onHistory: { navigate(to: .history) }
            )
        case .settings:
            SettingsView(store: store, onBack: { navigate(to: .home, forward: false) })
        case .history:
            HistoryView(store: store, onBack: { navigate(to: .home, forward: false) })
        case .intro(let phase):
            IntroView(phase: phase) { navigate(to: .testing(phase)) }
        case .testing(let phase):
            testingView(for: phase)
        case .results(let lt, let rt, let la, let ra, let bl, let ss, let er):
            ResultsView(
                leftTapScore: lt, rightTapScore: rt,
                leftArmScore: la, rightArmScore: ra,
                balanceScore: bl, speechScore: ss,
                eyesResult: er,
                emergencyNumber: store.emergencyNumber,
                emergencyContact1: store.emergencyContact1,
                emergencyContact2: store.emergencyContact2,
                onRestart: { navigate(to: .home, forward: false) }
            )
            .onAppear {
                store.addResult(TestResult(
                    leftTap: lt, rightTap: rt, leftArm: la, rightArm: ra,
                    balanceScore: bl, speechScore: ss, eyesResult: er
                ))
            }
        }
    }
    
    @ViewBuilder
    func testingView(for phase: TestPhase) -> some View {
        switch phase {
        case .tapLeft:
            ActiveTestWrapper(phase: phase) {
                DexterityTestView(hand: "Left Hand", color: .blue) { score in
                    leftTapScore = score; navigate(to: .intro(.tapRight))
                }
            }
        case .tapRight:
            ActiveTestWrapper(phase: phase) {
                DexterityTestView(hand: "Right Hand", color: .orange) { score in
                    rightTapScore = score; navigate(to: .intro(.armLeft))
                }
            }
        case .armLeft:
            ActiveTestWrapper(phase: phase) {
                ArmTestView(arm: "Left", color: .purple) { stability in
                    leftArmScore = stability; navigate(to: .intro(.armRight))
                }
            }
        case .armRight:
            ActiveTestWrapper(phase: phase) {
                ArmTestView(arm: "Right", color: .teal) { stability in
                    rightArmScore = stability; navigate(to: .intro(.balance))
                }
            }
        case .balance:
            ActiveTestWrapper(phase: phase) {
                BalanceTestView { sway in
                    balanceScore = sway; navigate(to: .intro(.speech1))
                }
            }
        case .speech1:
            ActiveTestWrapper(phase: phase) {
                SpeechTestView(sentence: "The sun is shining bright and warm today", sentenceNumber: 1) { score in
                    speechScores.append(score); navigate(to: .intro(.speech2))
                }
            }
        case .speech2:
            ActiveTestWrapper(phase: phase) {
                SpeechTestView(sentence: "I would like a glass of cold water please", sentenceNumber: 2) { score in
                    speechScores.append(score); navigate(to: .intro(.eyes))
                }
            }
        case .eyes:
            ActiveTestWrapper(phase: phase) {
                EyesTestView { result in
                    let avg = speechScores.isEmpty ? 0 : speechScores.reduce(0, +) / Double(speechScores.count)
                    navigate(to: .results(
                        leftTap: leftTapScore, rightTap: rightTapScore,
                        leftArm: leftArmScore, rightArm: rightArmScore,
                        balance: balanceScore, speechScore: avg, eyesScore: result
                    ))
                }
            }
        }
    }
}

// MARK: - Splash Screen
struct SplashView: View {
    var onFinish: () -> Void
    @State private var pulse = false
    @State private var opacity = 0.0
    @State private var scale = 0.8
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.85, green: 0.15, blue: 0.15), Color(red: 0.6, green: 0.08, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.1)).frame(width: 140, height: 140)
                        .scaleEffect(pulse ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                    Image(systemName: "heart.fill").font(.system(size: 60)).foregroundColor(.white)
                }
                Text("BEFAST").font(.system(size: 52, weight: .bold)).foregroundColor(.white)
                Text("Stroke Detection Assistant").font(.title3).foregroundColor(.white.opacity(0.75))
            }
            .opacity(opacity).scaleEffect(scale)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { opacity = 1.0; scale = 1.0 }
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeIn(duration: 0.3)) { opacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onFinish() }
            }
        }
    }
}

// MARK: - Onboarding View
struct OnboardingView: View {
    var onComplete: () -> Void
    @State private var currentPage = 0
    
    let pages: [(icon: String, color: Color, title: String, subtitle: String, description: String)] = [
        ("brain.head.profile", Color(red: 0.85, green: 0.15, blue: 0.15), "Detect Stroke Early", "Every second counts",
         "BEFAST is a personal stroke screening assistant that helps you or someone nearby quickly identify warning signs of a stroke — before it's too late."),
        ("checklist", Color(red: 0.3, green: 0.4, blue: 0.7), "8 Guided Tests", "Fully automated • ~3 minutes",
         "The app walks you through arm coordination, balance, speech, and vision tests. No buttons to press during testing — just follow the instructions on screen."),
        ("cross.case.fill", Color(red: 0.1, green: 0.55, blue: 0.35), "Built on Real Medicine", "B.E.F.A.S.T. method",
         "Every test is based on the B.E.F.A.S.T. stroke recognition method, used by medical professionals worldwide. This app is an educational tool — always call emergency services if you suspect a stroke.")
    ]
    
    var body: some View {
        ZStack {
            pages[currentPage].color.ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: currentPage)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(i == currentPage ? 1.0 : 0.3))
                            .frame(width: i == currentPage ? 24 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: currentPage)
                    }
                }.padding(.top, 60)
                Spacer()
                ZStack {
                    Circle().fill(Color.white.opacity(0.15)).frame(width: 160, height: 160)
                    Image(systemName: pages[currentPage].icon).font(.system(size: 65)).foregroundColor(.white)
                }.padding(.bottom, 40)
                VStack(spacing: 16) {
                    Text(pages[currentPage].title).font(.system(size: 32, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                    Text(pages[currentPage].subtitle).font(.subheadline.bold()).foregroundColor(.white.opacity(0.65))
                    Text(pages[currentPage].description).font(.body).foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(.horizontal, 32).padding(.top, 4)
                }
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        if currentPage < 2 { currentPage += 1 } else { onComplete() }
                    }
                }) {
                    HStack {
                        Text(currentPage < 2 ? "Next" : "Get Started").font(.title3.bold())
                        if currentPage < 2 { Image(systemName: "arrow.right").font(.title3.bold()) }
                    }
                    .foregroundColor(pages[currentPage].color).frame(maxWidth: .infinity).padding()
                    .background(Color.white).cornerRadius(16)
                }.padding(.horizontal, 40).padding(.bottom, 60)
            }
        }
        .gesture(DragGesture().onEnded { value in
            if value.translation.width < -50 && currentPage < 2 { withAnimation { currentPage += 1 } }
            else if value.translation.width > 50 && currentPage > 0 { withAnimation { currentPage -= 1 } }
        })
    }
}

// MARK: - Home Screen
struct HomeView: View {
    var onStart: () -> Void
    var onSettings: () -> Void
    var onHistory: () -> Void
    @State private var pulse = false
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.85, green: 0.15, blue: 0.15), Color(red: 0.6, green: 0.08, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onHistory) {
                        Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    Button(action: onSettings) {
                        Image(systemName: "gearshape.fill").font(.title3).foregroundColor(.white.opacity(0.8))
                    }
                }.padding(.horizontal, 24).padding(.top, 16)
                Spacer()
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.1)).frame(width: 130, height: 130)
                            .scaleEffect(pulse ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulse)
                        Image(systemName: "heart.fill").font(.system(size: 55)).foregroundColor(.white)
                    }
                    VStack(spacing: 8) {
                        Text("BEFAST").font(.system(size: 48, weight: .bold)).foregroundColor(.white)
                        Text("Stroke Detection Assistant").font(.title3).foregroundColor(.white.opacity(0.75))
                    }
                    HStack(spacing: 8) {
                        TestPill(icon: "hand.tap.fill", label: "Arms")
                        TestPill(icon: "figure.stand", label: "Balance")
                        TestPill(icon: "mic.fill", label: "Speech")
                        TestPill(icon: "eye.fill", label: "Eyes")
                    }.padding(.top, 8)
                    Text("8 tests • ~3 minutes • fully guided").font(.caption).foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                VStack(spacing: 12) {
                    Button(action: onStart) {
                        Text("Start Full Test").font(.title2.bold())
                            .foregroundColor(Color(red: 0.75, green: 0.12, blue: 0.12))
                            .frame(maxWidth: .infinity).padding().background(Color.white).cornerRadius(16)
                    }
                    Text("Tap the button above if you suspect a stroke").font(.caption).foregroundColor(.white.opacity(0.4))
                }.padding(.horizontal, 40).padding(.bottom, 50)
            }
        }.onAppear { pulse = true }
    }
}

struct TestPill: View {
    var icon: String
    var label: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(.white)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(0.12)).cornerRadius(10)
    }
}

// MARK: - Disclaimer View
struct DisclaimerView: View {
    var onAccept: () -> Void
    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.95, blue: 0.97).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 25) {
                    Image(systemName: "exclamationmark.shield.fill").font(.system(size: 60))
                        .foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6)).padding(.top, 60)
                    Text("Important Disclaimer").font(.system(size: 32, weight: .bold)).foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.3))
                    VStack(alignment: .leading, spacing: 16) {
                        DisclaimerItem(icon: "cross.case.fill", title: "Not a Medical Device",
                                       text: "This app is NOT a certified medical device and cannot diagnose a stroke or any medical condition.")
                        DisclaimerItem(icon: "phone.arrow.up.right.fill", title: "Always Call Emergency Services",
                                       text: "If you suspect a stroke, call 112/911 immediately. Do NOT rely on this app for medical decisions.")
                        DisclaimerItem(icon: "info.circle.fill", title: "Educational Tool Only",
                                       text: "This app is designed as an awareness and screening aid based on the B.E.F.A.S.T method. It is not a substitute for professional medical evaluation.")
                        DisclaimerItem(icon: "hand.raised.fill", title: "No Liability",
                                       text: "The developers assume no responsibility for any actions taken or not taken based on the results of this app.")
                    }.padding(.horizontal, 24)
                    Button(action: onAccept) {
                        Text("I Understand & Accept").font(.title3.bold()).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding()
                            .background(Color(red: 0.3, green: 0.4, blue: 0.6)).cornerRadius(16)
                    }.padding(.horizontal, 40).padding(.top, 10).padding(.bottom, 60)
                }
            }
        }
    }
}

struct DisclaimerItem: View {
    var icon: String
    var title: String
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6)).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.3))
                Text(text).font(.subheadline).foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.5)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding().frame(maxWidth: .infinity, minHeight: 90)
        .background(Color.white).cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
    }
}

// MARK: - Active Test Wrapper
struct ActiveTestWrapper<Content: View>: View {
    var phase: TestPhase
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { BEFASTHeader(phase: phase); content }
    }
}

// MARK: - BEFAST Header
struct BEFASTHeader: View {
    var phase: TestPhase
    private let labels = ["A₁", "A₂", "A₃", "A₄", "B", "S₁", "S₂", "E"]
    private let icons = ["hand.point.left.fill", "hand.point.right.fill", "figure.arms.open",
                         "figure.arms.open", "figure.stand", "mic.fill", "mic.fill", "eye.fill"]
    
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    VStack(spacing: 2) {
                        Image(systemName: icons[i]).font(.system(size: 10))
                            .foregroundColor(phase.befastProgress[i] ? .white : .white.opacity(0.25))
                        Text(labels[i]).font(.system(size: 7, weight: .bold))
                            .foregroundColor(phase.befastProgress[i] ? .white : .white.opacity(0.25))
                    }
                    if i < 7 {
                        Rectangle().fill(phase.befastProgress[i] ? Color.white : Color.white.opacity(0.2)).frame(width: 8, height: 2)
                    }
                }
            }
            Text(phase.title).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
        }
        .padding(.vertical, 10).padding(.horizontal, 12).frame(maxWidth: .infinity)
        .background(phase.color.opacity(0.95))
    }
}

// MARK: - Intro Screen
struct IntroView: View {
    var phase: TestPhase
    var onReady: () -> Void
    @State private var timeLeft = 5
    @State private var animating = false
    // OPTIMIZED: Random bar heights moved to @State so they don't recalculate on every render
    @State private var barHeights: [CGFloat] = [20, 35, 15, 40, 25]
    
    var body: some View {
        ZStack {
            phase.color.ignoresSafeArea()
            VStack(spacing: 25) {
                BEFASTHeader(phase: phase)
                Spacer()
                ZStack {
                    Circle().fill(Color.white.opacity(0.12)).frame(width: 200, height: 200)
                        .scaleEffect(animating ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animating)
                    demoContent
                }
                Text(phase.title).font(.system(size: 28, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                Text(phase.instruction).font(.body).foregroundColor(.white.opacity(0.85)).multilineTextAlignment(.center).padding(.horizontal, 30)
                Spacer()
                VStack(spacing: 8) {
                    Text("Starting in \(timeLeft)...").font(.title2.bold()).foregroundColor(.white)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.3)).frame(height: 8)
                            RoundedRectangle(cornerRadius: 8).fill(Color.white)
                                .frame(width: geo.size.width * CGFloat(timeLeft) / 5.0, height: 8)
                                .animation(.linear(duration: 0.9), value: timeLeft)
                        }
                    }.frame(height: 8).padding(.horizontal, 40)
                }.padding(.bottom, 60)
            }
        }
        .onAppear {
            animating = true
            startAutoAdvance()
        }
    }
    
    @ViewBuilder
    var demoContent: some View {
        switch phase {
        case .tapLeft, .tapRight:
            VStack(spacing: 10) {
                Image(systemName: phase.icon).font(.system(size: 60)).foregroundColor(.white)
                Circle().fill(Color.white.opacity(0.6)).frame(width: 40, height: 40)
                    .offset(y: animating ? -5 : 5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: animating)
            }
        case .armLeft, .armRight:
            VStack(spacing: 0) {
                Image(systemName: "iphone").font(.system(size: 40)).foregroundColor(.white)
                    .offset(y: animating ? -8 : 0)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animating)
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.8)).frame(width: 20, height: 80)
                    .offset(y: animating ? -8 : 0)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animating)
            }
        case .balance:
            VStack(spacing: 8) {
                Image(systemName: "figure.stand").font(.system(size: 70)).foregroundColor(.white)
                    .offset(x: animating ? -6 : 6)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: animating)
                Image(systemName: "iphone").font(.system(size: 28)).foregroundColor(.white.opacity(0.7))
            }
        case .speech1, .speech2:
            // OPTIMIZED: Uses @State barHeights instead of CGFloat.random in body
            VStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.system(size: 60)).foregroundColor(.white)
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.7))
                            .frame(width: 4, height: animating ? barHeights[i] : 10)
                            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(i) * 0.1), value: animating)
                    }
                }
            }
        case .eyes:
            ZStack {
                Image(systemName: "camera.fill").font(.system(size: 50)).foregroundColor(.white.opacity(0.3))
                Circle().fill(Color.white).frame(width: 28, height: 28)
                    .shadow(color: .white.opacity(0.6), radius: 8)
                    .offset(x: animating ? 45 : -45, y: animating ? -15 : 15)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: animating)
            }
        }
    }
    
    func startAutoAdvance() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if timeLeft > 0 { timeLeft -= 1 } else { t.invalidate(); onReady() }
        }
    }
}

// MARK: - Dexterity Test
struct DexterityTestView: View {
    var hand: String
    var color: Color
    var onComplete: (Int) -> Void
    
    @State private var circles: [CircleTarget] = []
    @State private var score = 0
    @State private var timeLeft: Double = 15
    @State private var gameOver = false
    @State private var countdown = 3
    @State private var countingDown = true
    @State private var timer: Timer?
    @State private var screenSize: CGSize = .zero
    let haptic = UIImpactFeedbackGenerator(style: .medium)
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if countingDown {
                    VStack(spacing: 20) {
                        Text("Get Ready!").font(.largeTitle.bold()).foregroundColor(.white)
                        Text("\(countdown)").font(.system(size: 120, weight: .bold)).foregroundColor(color)
                            .animation(.easeInOut(duration: 0.3), value: countdown)
                    }
                } else if !gameOver {
                    ForEach(circles) { circle in
                        Circle().fill(color).frame(width: circle.size, height: circle.size)
                            .position(circle.position).onTapGesture { tapCircle(circle) }
                    }
                    VStack {
                        HStack {
                            Text("\(score) taps").foregroundColor(.white).font(.title2.bold())
                            Spacer()
                            Text("\(Int(timeLeft))s").foregroundColor(timeLeft <= 5 ? .red : .white).font(.title2.bold())
                        }.padding(.horizontal, 30).padding(.top, 10)
                        CountdownProgressBar(value: timeLeft, total: 15, color: timeLeft <= 5 ? .red : color)
                            .padding(.top, 4)
                        Spacer()
                    }
                }
            }
            .onAppear { screenSize = geo.size; startCountdown() }
            // OPTIMIZED: Cancel timer when view disappears
            .onDisappear { timer?.invalidate() }
        }
        .onChange(of: gameOver) {
            if gameOver {
                AudioServicesPlaySystemSound(1114)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onComplete(score) }
            }
        }
    }
    
    func startCountdown() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 0 { countdown -= 1 }
            else { t.invalidate(); countingDown = false; startGame() }
        }
    }
    
    func startGame() {
        spawnCircle()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if timeLeft > 0 { timeLeft -= 0.1 } else { timer?.invalidate(); gameOver = true }
        }
    }
    
    func spawnCircle() {
        let w = screenSize.width
        let h = screenSize.height
        let pad: CGFloat = 55
        
        let xLow  = hand == "Left Hand" ? w * 0.55 + pad : w * 0.10 + pad
        let xHigh = hand == "Left Hand" ? w * 0.90 - pad : w * 0.45 - pad
        let yLow  = h * 0.15 + pad
        let yHigh = h * 0.85 - pad
        
        // OPTIMIZED: Guard against invalid range on very small screens
        guard xLow < xHigh, yLow < yHigh else { return }
        
        let sizes: [CGFloat] = [50, 65, 80]
        circles = [CircleTarget(
            position: CGPoint(x: CGFloat.random(in: xLow...xHigh), y: CGFloat.random(in: yLow...yHigh)),
            size: sizes.randomElement() ?? 65
        )]
    }
    
    func tapCircle(_ circle: CircleTarget) { haptic.impactOccurred(); score += 1; spawnCircle() }
}

// MARK: - Arm Test View
struct ArmTestView: View {
    var arm: String
    var color: Color
    var onComplete: (Double) -> Void
    
    @State private var motionManager = CMMotionManager()
    @State private var currentShake = 0.0
    @State private var timeLeft: Double = 15
    @State private var countdown = 3
    @State private var countingDown = true
    @State private var done = false
    @State private var readings: [Double] = []
    @State private var timer: Timer?
    
    var stabilityColor: Color {
        currentShake < 0.3 ? .green : currentShake < 0.7 ? .orange : .red
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if countingDown {
                VStack(spacing: 20) {
                    Text("Raise your \(arm) arm!").font(.title.bold()).foregroundColor(.white)
                    Text("\(countdown)").font(.system(size: 120, weight: .bold)).foregroundColor(color)
                        .animation(.easeInOut(duration: 0.3), value: countdown)
                    Text("Hold phone flat in palm").font(.title3).foregroundColor(.gray)
                }
            } else if !done {
                VStack(spacing: 20) {
                    HStack {
                        Text("\(arm) Arm").foregroundColor(.white).font(.title2.bold())
                        Spacer()
                        Text("\(Int(timeLeft))s").foregroundColor(timeLeft <= 5 ? .red : .white).font(.title2.bold())
                    }.padding(.horizontal, 30).padding(.top, 10)
                    CountdownProgressBar(value: timeLeft, total: 15, color: color)
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 20).frame(width: 180, height: 180)
                        Circle().trim(from: 0, to: CGFloat(1 - min(currentShake, 1.0)))
                            .stroke(stabilityColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                            .frame(width: 180, height: 180).rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.2), value: currentShake)
                        VStack {
                            Image(systemName: currentShake < 0.3 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 36)).foregroundColor(stabilityColor)
                            Text(currentShake < 0.3 ? "Steady" : currentShake < 0.7 ? "Moving" : "Unstable")
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                }
            }
        }
        .onAppear { startCountdown() }
        // OPTIMIZED: Stop motion manager and cancel timer on disappear
        .onDisappear { motionManager.stopAccelerometerUpdates(); timer?.invalidate() }
        .onChange(of: done) {
            if done {
                AudioServicesPlaySystemSound(1114)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                let avg = readings.isEmpty ? 0 : readings.reduce(0, +) / Double(readings.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onComplete(avg) }
            }
        }
    }
    
    func startCountdown() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 0 { countdown -= 1 }
            else { t.invalidate(); countingDown = false; startTest() }
        }
    }
    
    func startTest() {
        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: .main) { data, _ in
            guard let data = data else { return }
            let shake = sqrt(pow(data.acceleration.x, 2) + pow(data.acceleration.y, 2) + pow(data.acceleration.z + 1, 2))
            currentShake = min(shake * 2, 1.0)
            readings.append(shake)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if timeLeft > 0 { timeLeft -= 0.1 }
            else { timer?.invalidate(); motionManager.stopAccelerometerUpdates(); done = true }
        }
    }
}

// MARK: - Balance Test View
struct BalanceTestView: View {
    var onComplete: (Double) -> Void
    let balanceColor = Color(red: 0.8, green: 0.4, blue: 0.1)
    
    @State private var motionManager = CMMotionManager()
    @State private var timeLeft: Double = 15
    @State private var countdown = 3
    @State private var countingDown = true
    @State private var done = false
    @State private var readings: [Double] = []
    @State private var currentSway = 0.0
    @State private var timer: Timer?
    
    var swayColor: Color { currentSway < 0.15 ? .green : currentSway < 0.3 ? .orange : .red }
    var swayLabel: String { currentSway < 0.15 ? "Stable" : currentSway < 0.3 ? "Some sway" : "Too much sway" }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if countingDown {
                VStack(spacing: 20) {
                    Image(systemName: "figure.stand").font(.system(size: 60)).foregroundColor(balanceColor)
                    Text("Stand up straight!").font(.title.bold()).foregroundColor(.white)
                    Text("Hold phone against your chest").font(.title3).foregroundColor(.gray)
                    Text("\(countdown)").font(.system(size: 100, weight: .bold)).foregroundColor(balanceColor)
                        .animation(.easeInOut(duration: 0.3), value: countdown)
                }.multilineTextAlignment(.center).padding(30)
            } else if !done {
                VStack(spacing: 20) {
                    HStack {
                        Text("Balance").foregroundColor(.white).font(.title2.bold())
                        Spacer()
                        Text("\(Int(timeLeft))s").foregroundColor(timeLeft <= 5 ? .red : .white).font(.title2.bold())
                    }.padding(.horizontal, 30).padding(.top, 10)
                    CountdownProgressBar(value: timeLeft, total: 15, color: balanceColor)
                    Spacer()
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.1), lineWidth: 20).frame(width: 200, height: 200)
                        Circle().trim(from: 0, to: CGFloat(1 - min(currentSway * 3, 1.0)))
                            .stroke(swayColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                            .frame(width: 200, height: 200).rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.2), value: currentSway)
                        VStack(spacing: 8) {
                            Image(systemName: currentSway < 0.15 ? "figure.stand" : "figure.walk")
                                .font(.system(size: 44)).foregroundColor(swayColor)
                            Text(swayLabel).font(.caption.bold()).foregroundColor(swayColor)
                        }
                    }
                    Spacer()
                    Text("Keep still. Breathe normally.").font(.caption).foregroundColor(.gray).padding(.bottom, 30)
                }
            }
        }
        .onAppear { startCountdown() }
        // OPTIMIZED: Stop motion manager and cancel timer on disappear
        .onDisappear { motionManager.stopAccelerometerUpdates(); timer?.invalidate() }
        .onChange(of: done) {
            if done {
                AudioServicesPlaySystemSound(1114)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                let avg = readings.isEmpty ? 0 : readings.reduce(0, +) / Double(readings.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onComplete(avg) }
            }
        }
    }
    
    func startCountdown() {
        countdown = 3; countingDown = true
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 0 { countdown -= 1 }
            else { t.invalidate(); countingDown = false; startTest() }
        }
    }
    
    func startTest() {
        motionManager.accelerometerUpdateInterval = 0.1
        motionManager.startAccelerometerUpdates(to: .main) { data, _ in
            guard let data = data else { return }
            let sway = sqrt(pow(data.acceleration.x, 2) + pow(data.acceleration.y + 1, 2) + pow(data.acceleration.z, 2))
            currentSway = min(sway, 1.0); readings.append(sway)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if timeLeft > 0 { timeLeft -= 0.1 }
            else { timer?.invalidate(); motionManager.stopAccelerometerUpdates(); done = true }
        }
    }
}

// MARK: - Speech Test View
struct SpeechTestView: View {
    var sentence: String
    var sentenceNumber: Int
    var onComplete: (Double) -> Void
    
    @State private var recognizedText = ""
    @State private var isListening = false
    @State private var countdown = 3
    @State private var countingDown = true
    @State private var timeLeft: Double = 10
    @State private var timer: Timer?
    @State private var audioEngine = AVAudioEngine()
    @State private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 25) {
                Spacer()
                VStack(spacing: 12) {
                    Text("Read this out loud:").font(.body).foregroundColor(.gray)
                    Text(sentence).font(.title2.bold()).foregroundColor(.white).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                if countingDown {
                    VStack(spacing: 12) {
                        Text("Get ready to read...").font(.title3).foregroundColor(.gray)
                        Text("\(countdown)").font(.system(size: 80, weight: .bold)).foregroundColor(.indigo)
                            .animation(.easeInOut(duration: 0.3), value: countdown)
                    }.padding(.top, 20)
                } else if isListening {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle().fill(Color.red.opacity(0.3)).frame(width: 70, height: 70)
                            Circle().fill(Color.red).frame(width: 44, height: 44)
                            Image(systemName: "mic.fill").font(.system(size: 20)).foregroundColor(.white)
                        }
                        Text("Listening... \(Int(timeLeft))s").font(.title3.bold()).foregroundColor(.red)
                        CountdownProgressBar(value: timeLeft, total: 10, color: .indigo)
                    }
                }
                VStack(spacing: 8) {
                    Text("What I heard:").font(.body).foregroundColor(.gray)
                    Text(recognizedText.isEmpty ? "..." : recognizedText)
                        .font(.title3).foregroundColor(recognizedText.isEmpty ? .gray : .indigo)
                        .multilineTextAlignment(.center).padding(.horizontal, 30).frame(minHeight: 60)
                }
                .padding().background(Color.white.opacity(0.1)).cornerRadius(16).padding(.horizontal, 20)
                Spacer()
            }
        }
        .onAppear { requestPermissions(); startCountdown() }
        // OPTIMIZED: Stop audio engine on disappear
        .onDisappear {
            timer?.invalidate()
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            recognitionTask?.cancel()
        }
    }
    
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }
    
    func startCountdown() {
        countdown = 3; countingDown = true
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 0 { countdown -= 1 }
            else { t.invalidate(); countingDown = false; startListening() }
        }
    }
    
    func startListening() {
        recognizedText = ""; timeLeft = 10; isListening = true
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, _ in
            if let result = result { recognizedText = result.bestTranscription.formattedString }
        }
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in recognitionRequest.append(buffer) }
        audioEngine.prepare()
        try? audioEngine.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if timeLeft > 0 { timeLeft -= 0.1 } else { stopListening() }
        }
    }
    
    func stopListening() {
        timer?.invalidate()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio(); recognitionTask?.cancel(); isListening = false
        AudioServicesPlaySystemSound(1114)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let score = calculateScore(target: sentence, spoken: recognizedText)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onComplete(score) }
    }
    
    func calculateScore(target: String, spoken: String) -> Double {
        let targetWords = Set(target.lowercased().split(separator: " ").map(String.init))
        let spokenWords = Set(spoken.lowercased().split(separator: " ").map(String.init))
        guard !targetWords.isEmpty, !spokenWords.isEmpty else { return 0 }
        return Double(targetWords.intersection(spokenWords).count) / Double(targetWords.count)
    }
}

// MARK: - Eyes Test View
struct EyesTestView: View {
    var onComplete: (EyesResult) -> Void
    
    @StateObject private var tracker = EyeTracker()
    @State private var cameraGranted = false
    let dotStops: [(x: CGFloat, y: CGFloat, side: String)] = [
        (0.50, 0.40, "center"), (0.15, 0.35, "left"),   (0.85, 0.35, "right"),
        (0.50, 0.50, "center"), (0.15, 0.55, "left"),   (0.85, 0.55, "right"),
        (0.50, 0.65, "center"), (0.15, 0.65, "left"),   (0.85, 0.65, "right"),
    ]
    
    @State private var currentStop = 0
    @State private var countdown = 3
    @State private var countingDown = true
    @State private var timeLeft: Double = 20
    @State private var done = false
    @State private var baselineEyeX: CGFloat = 0.5
    @State private var hasBaseline = false
    @State private var totalChecks = 0
    @State private var successfulTracks = 0
    @State private var leftMisses = 0
    @State private var rightMisses = 0
    @State private var dotTimer: Timer?
    @State private var gameTimer: Timer?
    
    let dotColor = Color(red: 0.1, green: 0.6, blue: 0.4)
    var activeStop: (x: CGFloat, y: CGFloat, side: String) { dotStops[currentStop % dotStops.count] }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if cameraGranted {
                    CameraPreviewView(session: tracker.captureSession).ignoresSafeArea().opacity(0.45)
                    Color.black.opacity(0.45).ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
                if countingDown {
                    VStack(spacing: 20) {
                        Text("Get Ready!").font(.largeTitle.bold()).foregroundColor(.white)
                        Text("\(countdown)").font(.system(size: 120, weight: .bold)).foregroundColor(dotColor)
                            .animation(.easeInOut(duration: 0.3), value: countdown)
                        Text("Follow the dot with your eyes only").font(.title3).foregroundColor(.gray)
                        Text("Keep your head still").font(.subheadline).foregroundColor(.gray.opacity(0.7))
                        if cameraGranted {
                            HStack(spacing: 6) {
                                Circle().fill(tracker.faceDetected ? Color.green : Color.orange).frame(width: 10, height: 10)
                                Text(tracker.faceDetected ? "Face detected — ready!" : "Position your face in view")
                                    .font(.subheadline).foregroundColor(tracker.faceDetected ? .green : .orange)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(Color.white.opacity(0.1)).cornerRadius(20)
                        }
                    }.padding(30)
                } else if !done {
                    Circle().fill(dotColor).frame(width: 62, height: 62)
                        .shadow(color: dotColor.opacity(0.8), radius: 16)
                        .position(x: geo.size.width * activeStop.x, y: geo.size.height * activeStop.y)
                        .animation(.easeInOut(duration: 1.5), value: currentStop)
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("👁 Eyes Test").foregroundColor(.white).font(.title2.bold())
                                if cameraGranted {
                                    Text(tracker.faceDetected ? "Camera tracking ✓" : "No face detected")
                                        .font(.caption).foregroundColor(tracker.faceDetected ? .green : .orange)
                                }
                            }
                            Spacer()
                            Text("\(Int(timeLeft))s").foregroundColor(timeLeft <= 5 ? .red : .white).font(.title2.bold())
                        }.padding(.horizontal, 30).padding(.top, 10)
                        CountdownProgressBar(value: timeLeft, total: 20, color: dotColor).padding(.top, 4)
                        Spacer()
                        HStack(spacing: 40) {
                            VStack(spacing: 4) {
                                Text("\(successfulTracks)").font(.system(size: 32, weight: .bold)).foregroundColor(dotColor)
                                Text("Tracked").font(.caption).foregroundColor(.gray)
                            }
                            VStack(spacing: 4) {
                                Text("\(leftMisses + rightMisses)").font(.system(size: 32, weight: .bold)).foregroundColor(.red)
                                Text("Missed").font(.caption).foregroundColor(.gray)
                            }
                        }.padding(.bottom, 50)
                    }
                }
            }
            .onAppear {
                requestCamera { granted in
                    cameraGranted = granted
                    if granted { tracker.start() }
                    startCountdown()
                }
            }
            .onDisappear {
                tracker.stop()
                dotTimer?.invalidate()
                gameTimer?.invalidate()
            }
        }
        .onChange(of: done) {
            if done {
                tracker.stop()
                dotTimer?.invalidate(); gameTimer?.invalidate()
                AudioServicesPlaySystemSound(1114)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                let result = EyesResult(totalDots: max(totalChecks, 1), tappedDots: successfulTracks,
                                        leftMisses: leftMisses, rightMisses: rightMisses)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onComplete(result) }
            }
        }
    }
    
    func requestCamera(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { completion(granted) } }
        default: completion(false)
        }
    }
    
    func startCountdown() {
        countdown = 3; countingDown = true
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countdown > 0 { countdown -= 1 }
            else {
                t.invalidate(); countingDown = false
                if tracker.faceDetected { baselineEyeX = tracker.avgEyeX; hasBaseline = true }
                startTest()
            }
        }
    }
    
    func startTest() {
        currentStop = 0
        gameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if timeLeft > 0 { timeLeft -= 0.1 }
            else { gameTimer?.invalidate(); dotTimer?.invalidate(); done = true }
        }
        dotTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            evaluateTracking(); currentStop += 1
            if activeStop.side == "center" && tracker.faceDetected { baselineEyeX = tracker.avgEyeX; hasBaseline = true }
        }
    }
    
    func evaluateTracking() {
        let stop = dotStops[currentStop % dotStops.count]
        if stop.side == "center" {
            if cameraGranted && tracker.faceDetected { successfulTracks += 1 }
            else if !cameraGranted { successfulTracks += 1 }
            totalChecks += 1; return
        }
        totalChecks += 1
        guard cameraGranted else { successfulTracks += 1; return }
        guard tracker.faceDetected && hasBaseline else {
            stop.side == "left" ? (leftMisses += 1) : (rightMisses += 1); return
        }
        let delta = tracker.avgEyeX - baselineEyeX
        let threshold: CGFloat = 0.018
        if stop.side == "left" {
            delta < -threshold ? (successfulTracks += 1) : (leftMisses += 1)
        } else {
            delta > threshold ? (successfulTracks += 1) : (rightMisses += 1)
        }
    }
}

// MARK: - Results Screen
struct ResultsView: View {
    var leftTapScore: Int, rightTapScore: Int
    var leftArmScore: Double, rightArmScore: Double
    var balanceScore: Double, speechScore: Double
    var eyesResult: EyesResult
    var emergencyNumber: String
    var emergencyContact1: String, emergencyContact2: String
    var onRestart: () -> Void
    
    @State private var showingSMS = false
    @State private var smsAlertSent = false
    
    var tapWarning: Bool { abs(leftTapScore - rightTapScore) >= 8 }
    var leftArmUnstable: Bool { leftArmScore >= 0.3 }
    var rightArmUnstable: Bool { rightArmScore >= 0.3 }
    var armWarning: Bool { leftArmUnstable || rightArmUnstable || abs(leftArmScore - rightArmScore) >= 0.3 }
    var balanceWarning: Bool { balanceScore >= 0.25 }
    var speechWarning: Bool { speechScore < 0.7 }
    var anyWarning: Bool { tapWarning || armWarning || balanceWarning || speechWarning || eyesResult.hasWarning }
    var hasEmergencyContacts: Bool { !emergencyContact1.isEmpty || !emergencyContact2.isEmpty }
    var smsRecipients: [String] { [emergencyContact1, emergencyContact2].filter { !$0.isEmpty } }
    
    var smsMessage: String {
        """
        ⚠️ BEFAST STROKE ALERT
        
        This person may be showing signs of a stroke.
        
        Results:
        • Tap Test: \(tapWarning ? "⚠️ Warning" : "✅ Normal")
        • Arm Stability: \(armWarning ? "⚠️ Warning" : "✅ Normal")
        • Balance: \(balanceWarning ? "⚠️ Warning" : "✅ Normal")
        • Speech: \(speechWarning ? "⚠️ Warning" : "✅ Normal")
        • Eyes: \(eyesResult.hasWarning ? "⚠️ Warning" : "✅ Normal")
        
        Please check on them immediately and call \(emergencyNumber) if needed.
        
        Sent from BEFAST Stroke Detection Assistant.
        """
    }
    
    var resultSummary: String {
        """
        BEFAST Stroke Screening Results
        Date: \(Date().formatted(date: .long, time: .shortened))
        
        TAP TEST
        Left Hand: \(leftTapScore) taps | Right Hand: \(rightTapScore) taps
        Status: \(tapWarning ? "⚠️ Warning" : "✅ Normal")
        
        ARM STABILITY
        Left Arm: \(leftArmUnstable ? "Unstable" : "Stable") | Right Arm: \(rightArmUnstable ? "Unstable" : "Stable")
        Status: \(armWarning ? "⚠️ Warning" : "✅ Normal")
        
        BALANCE
        Body Sway: \(balanceWarning ? "Unstable" : "Stable")
        Status: \(balanceWarning ? "⚠️ Warning" : "✅ Normal")
        
        SPEECH
        Accuracy: \(Int(speechScore * 100))%
        Status: \(speechWarning ? "⚠️ Warning" : "✅ Normal")
        
        EYES
        Tracking: \(Int(eyesResult.accuracy * 100))%
        Status: \(eyesResult.hasWarning ? "⚠️ Warning" : "✅ Normal")
        
        OVERALL: \(anyWarning ? "⚠️ WARNING — Seek medical attention immediately" : "✅ ALL CLEAR — No signs of impairment")
        
        Generated by BEFAST Stroke Detection Assistant.
        This is NOT a medical diagnosis. Always consult a healthcare professional.
        """
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: anyWarning
                ? [Color(red: 0.55, green: 0.1, blue: 0.1), Color(red: 0.75, green: 0.15, blue: 0.15)]
                : [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.85, green: 0.9, blue: 0.95)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 10) {
                        Image(systemName: anyWarning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 60))
                            .foregroundColor(anyWarning ? .white : Color(red: 0.2, green: 0.6, blue: 0.4))
                        Text(anyWarning ? "Warning" : "All Clear")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(anyWarning ? .white : Color(red: 0.2, green: 0.3, blue: 0.35))
                        Text(anyWarning ? "Signs of possible impairment detected" : "No signs of impairment detected")
                            .font(.subheadline)
                            .foregroundColor(anyWarning ? .white.opacity(0.8) : Color(red: 0.4, green: 0.45, blue: 0.5))
                            .multilineTextAlignment(.center)
                    }.padding(.top, 50)
                    
                    ResultCardMedical(title: "Tap Test", icon: "hand.tap.fill", passed: !tapWarning, darkMode: anyWarning) {
                        MedicalScoreRow(label: "Left Hand", value: "\(leftTapScore) taps", warning: false, darkMode: anyWarning)
                        MedicalScoreRow(label: "Right Hand", value: "\(rightTapScore) taps", warning: false, darkMode: anyWarning)
                        if tapWarning { MedicalWarningLabel(text: "Difference ≥ 8 taps detected", darkMode: anyWarning) }
                    }
                    ResultCardMedical(title: "Arm Stability", icon: "figure.arms.open", passed: !armWarning, darkMode: anyWarning) {
                        MedicalScoreRow(label: "Left Arm", value: leftArmUnstable ? "Unstable" : "Stable", warning: leftArmUnstable, darkMode: anyWarning)
                        MedicalScoreRow(label: "Right Arm", value: rightArmUnstable ? "Unstable" : "Stable", warning: rightArmUnstable, darkMode: anyWarning)
                        if armWarning { MedicalWarningLabel(text: "Arm instability detected", darkMode: anyWarning) }
                    }
                    ResultCardMedical(title: "Balance", icon: "figure.stand", passed: !balanceWarning, darkMode: anyWarning) {
                        MedicalScoreRow(label: "Body Sway", value: balanceWarning ? "Unstable" : "Stable", warning: balanceWarning, darkMode: anyWarning)
                        if balanceWarning { MedicalWarningLabel(text: "Balance issues detected", darkMode: anyWarning) }
                    }
                    ResultCardMedical(title: "Speech", icon: "mic.fill", passed: !speechWarning, darkMode: anyWarning) {
                        MedicalScoreRow(label: "Accuracy", value: "\(Int(speechScore * 100))%", warning: speechWarning, darkMode: anyWarning)
                        if speechWarning { MedicalWarningLabel(text: "Speech difficulty detected", darkMode: anyWarning) }
                    }
                    ResultCardMedical(title: "Eyes", icon: "eye.fill", passed: !eyesResult.hasWarning, darkMode: anyWarning) {
                        MedicalScoreRow(label: "Tracking", value: "\(Int(eyesResult.accuracy * 100))%", warning: eyesResult.accuracy < 0.6, darkMode: anyWarning)
                        MedicalScoreRow(label: "Left misses", value: "\(eyesResult.leftMisses)", warning: eyesResult.leftMisses >= 3, darkMode: anyWarning)
                        MedicalScoreRow(label: "Right misses", value: "\(eyesResult.rightMisses)", warning: eyesResult.rightMisses >= 3, darkMode: anyWarning)
                        if eyesResult.hasWarning { MedicalWarningLabel(text: eyesResult.summaryText, darkMode: anyWarning) }
                    }
                    
                    VStack(spacing: 12) {
                        if anyWarning {
                            Button(action: {
                                if let url = URL(string: "tel://\(emergencyNumber)") { UIApplication.shared.open(url) }
                            }) {
                                HStack {
                                    Image(systemName: "phone.fill")
                                    Text("Call \(emergencyNumber) — Emergency")
                                }
                                .font(.title3.bold()).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding().background(Color.black).cornerRadius(16)
                            }
                            if hasEmergencyContacts && MFMessageComposeViewController.canSendText() {
                                Button(action: { showingSMS = true }) {
                                    HStack {
                                        Image(systemName: smsAlertSent ? "checkmark.circle.fill" : "message.fill")
                                        Text(smsAlertSent ? "Alert Sent ✓" : "Alert Emergency Contacts")
                                    }
                                    .font(.title3.bold()).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding()
                                    .background(smsAlertSent ? Color.green.opacity(0.6) : Color(red: 0.7, green: 0.1, blue: 0.1))
                                    .cornerRadius(16)
                                }
                            } else if hasEmergencyContacts {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Alert your emergency contacts:").font(.caption.bold()).foregroundColor(.white.opacity(0.7))
                                    ForEach([emergencyContact1, emergencyContact2].filter { !$0.isEmpty }, id: \.self) { contact in
                                        Button(action: {
                                            if let url = URL(string: "tel://\(contact)") { UIApplication.shared.open(url) }
                                        }) {
                                            HStack { Image(systemName: "phone.fill"); Text(contact) }
                                                .font(.body.bold()).foregroundColor(.white)
                                                .frame(maxWidth: .infinity).padding(10)
                                                .background(Color.white.opacity(0.2)).cornerRadius(10)
                                        }
                                    }
                                }
                                .padding().background(Color.white.opacity(0.1)).cornerRadius(16)
                            }
                        }
                        ShareLink(item: resultSummary) {
                            HStack { Image(systemName: "square.and.arrow.up"); Text("Share Results") }
                                .font(.title3.bold())
                                .foregroundColor(anyWarning ? .white : Color(red: 0.2, green: 0.5, blue: 0.7))
                                .frame(maxWidth: .infinity).padding()
                                .background(anyWarning ? Color.white.opacity(0.15) : Color.white).cornerRadius(16)
                        }
                        Button(action: onRestart) {
                            Text("Test Again").font(.title2.bold())
                                .foregroundColor(anyWarning ? .white : Color(red: 0.2, green: 0.5, blue: 0.7))
                                .frame(maxWidth: .infinity).padding()
                                .background(anyWarning ? Color.white.opacity(0.2) : Color.white).cornerRadius(16)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 60)
                }
            }
        }
        .sheet(isPresented: $showingSMS) {
            SMSComposer(recipients: smsRecipients, message: smsMessage, onDismiss: { showingSMS = false; smsAlertSent = true })
        }
    }
}

// MARK: - Medical UI Components
struct ResultCardMedical<Content: View>: View {
    var title: String, icon: String
    var passed: Bool, darkMode: Bool
    @ViewBuilder var content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundColor(darkMode ? .white : Color(red: 0.3, green: 0.4, blue: 0.5))
                Text(title).font(.title3.bold()).foregroundColor(darkMode ? .white : Color(red: 0.2, green: 0.25, blue: 0.3))
                Spacer()
                Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title3).foregroundColor(passed ? (darkMode ? .green : Color(red: 0.2, green: 0.7, blue: 0.4)) : .red)
            }
            Divider().background(darkMode ? Color.white.opacity(0.3) : Color.gray.opacity(0.3))
            content
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(darkMode ? Color.white.opacity(0.15) : Color.white)
            .shadow(color: darkMode ? .clear : Color.black.opacity(0.08), radius: 8, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(passed ? Color.clear : Color.red.opacity(darkMode ? 0.6 : 0.4), lineWidth: 2))
        .padding(.horizontal, 24)
    }
}

struct MedicalScoreRow: View {
    var label: String, value: String
    var warning: Bool, darkMode: Bool
    var body: some View {
        HStack {
            Text(label).foregroundColor(darkMode ? .white.opacity(0.8) : Color(red: 0.4, green: 0.45, blue: 0.5)).font(.body)
            Spacer()
            Text(value).font(.body.bold()).foregroundColor(warning ? .red : (darkMode ? .white : Color(red: 0.2, green: 0.25, blue: 0.3)))
        }
    }
}

struct MedicalWarningLabel: View {
    var text: String, darkMode: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundColor(darkMode ? .yellow : .red)
            Text(text).font(.caption).foregroundColor(darkMode ? .yellow : .red)
        }.padding(.top, 4)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var store: AppDataStore
    var onBack: () -> Void
    
    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.95, blue: 0.97).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Button(action: onBack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left"); Text("Back")
                            }.foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6))
                        }
                        Spacer()
                    }.padding(.horizontal, 24).padding(.top, 20)
                    
                    Text("Settings").font(.system(size: 32, weight: .bold)).foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.3))
                    
                    SettingsCard(title: "Emergency Number", icon: "phone.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Which number to call in emergencies:").font(.caption).foregroundColor(.gray)
                            TextField("112", text: $store.emergencyNumber)
                                .font(.title2.bold()).keyboardType(.phonePad).padding()
                                .background(Color(red: 0.95, green: 0.95, blue: 0.97)).cornerRadius(10)
                        }
                    }
                    SettingsCard(title: "Emergency Contacts", icon: "person.2.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("They will receive an SMS alert if a warning is detected:").font(.caption).foregroundColor(.gray)
                            VStack(spacing: 8) {
                                HStack {
                                    Image(systemName: "1.circle.fill").foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6))
                                    TextField("Phone number", text: $store.emergencyContact1)
                                        .keyboardType(.phonePad).padding(10)
                                        .background(Color(red: 0.95, green: 0.95, blue: 0.97)).cornerRadius(8)
                                }
                                HStack {
                                    Image(systemName: "2.circle.fill").foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6))
                                    TextField("Phone number", text: $store.emergencyContact2)
                                        .keyboardType(.phonePad).padding(10)
                                        .background(Color(red: 0.95, green: 0.95, blue: 0.97)).cornerRadius(8)
                                }
                            }
                            Text("Use phone numbers for SMS to work correctly.").font(.caption2).foregroundColor(.gray)
                        }
                    }
                    SettingsCard(title: "Reminders", icon: "bell.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Enable reminders").foregroundColor(Color(red: 0.2, green: 0.25, blue: 0.3))
                                Spacer()
                                Toggle("", isOn: $store.reminderEnabled)
                                    .onChange(of: store.reminderEnabled) {
                                        if store.reminderEnabled {
                                            ReminderManager.requestPermission { granted in
                                                if !granted { store.reminderEnabled = false }
                                            }
                                        }
                                    }
                            }
                            if store.reminderEnabled {
                                Divider()
                                Text("How often?").font(.caption).foregroundColor(.gray)
                                HStack(spacing: 10) {
                                    FrequencyButton(label: "Daily", selected: store.reminderFrequency == "daily") { store.reminderFrequency = "daily" }
                                    FrequencyButton(label: "Weekly", selected: store.reminderFrequency == "weekly") { store.reminderFrequency = "weekly" }
                                }
                                Text("Reminder sends at 9:00 AM").font(.caption).foregroundColor(.gray)
                            }
                        }
                    }
                    SettingsCard(title: "About", icon: "info.circle.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("BEFAST").font(.headline).foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.3))
                            Text("Stroke Detection Assistant • Version 1.0").font(.subheadline).foregroundColor(.gray)
                            Text("Educational tool based on the B.E.F.A.S.T. stroke recognition method. Not a certified medical device.")
                                .font(.caption).foregroundColor(.gray).padding(.top, 4)
                        }
                    }
                    VStack(spacing: 12) {
                        Button(action: { store.hasAcceptedDisclaimer = false; onBack() }) {
                            Text("Show Disclaimer Again").font(.subheadline).foregroundColor(.gray)
                        }
                        Button(action: { store.hasCompletedOnboarding = false; store.hasAcceptedDisclaimer = false; onBack() }) {
                            Text("Reset Onboarding").font(.subheadline).foregroundColor(.gray)
                        }
                    }.padding(.bottom, 60)
                }
            }
        }
    }
}

struct FrequencyButton: View {
    var label: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.subheadline.bold())
                .foregroundColor(selected ? .white : Color(red: 0.3, green: 0.4, blue: 0.6))
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(selected ? Color(red: 0.3, green: 0.4, blue: 0.6) : Color(red: 0.93, green: 0.95, blue: 0.97))
                .cornerRadius(10)
        }
    }
}

struct SettingsCard<Content: View>: View {
    var title: String, icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6))
                Text(title).font(.title3.bold()).foregroundColor(Color(red: 0.2, green: 0.25, blue: 0.3))
            }
            Divider()
            content
        }
        .padding().background(Color.white).cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
        .padding(.horizontal, 24)
    }
}

// MARK: - History View
struct HistoryView: View {
    @ObservedObject var store: AppDataStore
    var onBack: () -> Void
    
    var body: some View {
        ZStack {
            Color(red: 0.95, green: 0.95, blue: 0.97).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                            .foregroundColor(Color(red: 0.3, green: 0.4, blue: 0.6))
                    }
                    Spacer()
                    if !store.testResults.isEmpty {
                        Button(action: { store.testResults.removeAll() }) {
                            Text("Clear All").font(.subheadline).foregroundColor(.red)
                        }
                    }
                }.padding(.horizontal, 24).padding(.top, 20)
                
                Text("Test History").font(.system(size: 32, weight: .bold))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.3)).padding(.top, 10)
                
                if store.testResults.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 50)).foregroundColor(.gray.opacity(0.4))
                        Text("No tests yet").font(.title3).foregroundColor(.gray)
                        Text("Complete a test to see your history").font(.subheadline).foregroundColor(.gray.opacity(0.7))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.testResults) { result in HistoryCard(result: result) }
                        }.padding(.top, 16).padding(.bottom, 60)
                    }
                }
            }
        }
    }
}

struct HistoryCard: View {
    var result: TestResult
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: result.anyWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(result.anyWarning ? .red : Color(red: 0.2, green: 0.7, blue: 0.4))
                Text(result.anyWarning ? "Warning" : "All Clear")
                    .font(.headline).foregroundColor(Color(red: 0.2, green: 0.25, blue: 0.3))
                Spacer()
                Text(result.date, style: .date).font(.caption).foregroundColor(.gray)
            }
            Divider()
            HStack(spacing: 12) {
                HistoryMiniStat(label: "Tap L", value: "\(result.leftTap)", warning: result.tapWarning)
                HistoryMiniStat(label: "Tap R", value: "\(result.rightTap)", warning: result.tapWarning)
                HistoryMiniStat(label: "Arm L", value: result.leftArm < 0.3 ? "OK" : "!", warning: result.leftArm >= 0.3)
                HistoryMiniStat(label: "Arm R", value: result.rightArm < 0.3 ? "OK" : "!", warning: result.rightArm >= 0.3)
                HistoryMiniStat(label: "Bal", value: result.balanceScore < 0.25 ? "OK" : "!", warning: result.balanceWarning)
                HistoryMiniStat(label: "Speech", value: "\(Int(result.speechScore * 100))%", warning: result.speechWarning)
                HistoryMiniStat(label: "Eyes", value: "\(Int(result.eyesResult.accuracy * 100))%", warning: result.eyesWarning)
            }
        }
        .padding().background(Color.white).cornerRadius(14)
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(result.anyWarning ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1.5))
        .padding(.horizontal, 24)
    }
}

struct HistoryMiniStat: View {
    var label: String, value: String, warning: Bool
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 13, weight: .bold))
                .foregroundColor(warning ? .red : Color(red: 0.2, green: 0.25, blue: 0.3))
            Text(label).font(.system(size: 8)).foregroundColor(.gray)
        }
    }
}

// MARK: - Circle Model
struct CircleTarget: Identifiable {
    let id = UUID()
    var position: CGPoint
    var size: CGFloat
}

