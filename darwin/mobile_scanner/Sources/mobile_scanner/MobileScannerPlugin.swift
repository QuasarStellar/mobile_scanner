import AVFoundation
import Vision
import VideoToolbox

#if os(iOS)
  import Flutter
  import UIKit
  import MobileCoreServices
#else
  import AppKit
  import FlutterMacOS
#endif

public class MobileScannerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let registry: FlutterTextureRegistry
    
    // Sink for publishing event changes
    var sink: FlutterEventSink?

    // Texture id of the camera preview
    var textureId: Int64?

    // Capture session of the camera
    var captureSession: AVCaptureSession?

    // The selected camera
    weak var device: AVCaptureDevice?

    // Image to be sent to the texture
    var latestBuffer: CVImageBuffer?

    // optional window to limit scan search
    var scanWindow: CGRect?

    /// Whether to return the input image with the barcode event.
    /// This is static to avoid accessing `self` in the `VNDetectBarcodesRequest` callback.
    private static var returnImage: Bool = false

    /// The dispatch queue that will process ``captureOutput(_:didOutput:from:)`` calls.
    ///
    /// This queue is user initiated because it is tied to an ``AVCaptureSession``.
    private let sampleBufferQueue = DispatchQueue(label: "com.juliansteenbakker.mobile_scanner.captureOutputQueue", qos: .userInitiated)

    /// The dispatch queue that serializes `AVCaptureSession` setup, start, and teardown.
    ///
    /// This queue is user initiated because the user is waiting for the preview.
    /// iOS can starve background QoS work for many seconds when the system is busy (#1828),
    /// which keeps `start` from answering.
    private let sessionQueue = DispatchQueue(label: "dev.steenbakker.mobile_scanner.sessionQueue", qos: .userInitiated)

    private var sessionGeneration: UInt64 = 0
    private let bufferLock = NSLock()
    private let stateLock = NSLock()
    private var isStarting = false

    var detectionSpeed: DetectionSpeed = DetectionSpeed.noDuplicates

    var timeoutSeconds: Double = 0

    var symbologies:[VNBarcodeSymbology] = []

    var position = AVCaptureDevice.Position.back
    
    var standardZoomFactor: CGFloat = 1

    /// Whether the brightness of the camera scene should be measured.
    var reportSceneLuminance: Bool = false

    /// The next moment at which the scene brightness may be measured.
    private var nextSceneLuminanceTime: Double = 0

    /// Minimum pause between two scene brightness measurements, in seconds.
    private let sceneLuminanceInterval: Double = 0.4

    /// Target number of sampled pixels per scene brightness measurement.
    private let sceneLuminanceSamples: Int = 4096

#if os(iOS)
    var interfaceOrientationObserver: NSObjectProtocol?
#endif

    /// Observer for the notification that the app is about to terminate.
    private var willTerminateObserver: NSObjectProtocol?

    /// Whether the app is terminating, and the engine is therefore being destroyed.
    ///
    /// Only read and written on the main thread.
    private var terminating = false

    /// Whether a frame notification is already queued on the main queue.
    ///
    /// Written from ``sampleBufferQueue`` and cleared on the main queue, so it is guarded by
    /// ``frameNotificationLock``.
    private var pendingFrameNotification = false

    private let frameNotificationLock = NSLock()

    private var stopped: Bool {
        return device == nil || captureSession == nil
    }

    private var paused: Bool {
        return stopped && textureId != nil
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
#if os(iOS)
        let textures = registrar.textures()
        let messenger = registrar.messenger()
#else
        let textures = registrar.textures
        let messenger = registrar.messenger
#endif

        let instance = MobileScannerPlugin(textures)
        let method = FlutterMethodChannel(name:
                                            "dev.steenbakker.mobile_scanner/scanner/method", binaryMessenger: messenger)
        let event = FlutterEventChannel(name:
                                            "dev.steenbakker.mobile_scanner/scanner/event", binaryMessenger: messenger)

        registrar.addMethodCallDelegate(instance, channel: method)
        event.setStreamHandler(instance)

#if os(iOS)
        let orientationEvent = FlutterEventChannel(name:
                                            "dev.steenbakker.mobile_scanner/scanner/deviceOrientation", binaryMessenger: messenger)
        orientationEvent.setStreamHandler(DeviceOrientationStreamHandler())
#endif
    }
    
    init(_ registry: FlutterTextureRegistry) {
        self.registry = registry
        super.init()

#if os(iOS)
        let willTerminate = UIApplication.willTerminateNotification
#else
        let willTerminate = NSApplication.willTerminateNotification
#endif
        // Stop the camera as soon as the app starts terminating. The engine destroys its shell
        // during termination, after which any call into the texture registry dereferences
        // released memory, and the plugin has no way to observe that from the registry itself.
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: willTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            self?.terminating = true
            self?.releaseCamera()
        }
    }

    deinit {
        if let willTerminateObserver {
            NotificationCenter.default.removeObserver(willTerminateObserver)
        }
#if os(iOS)
        removeInterfaceOrientationObserver()
#endif
    }

    private func nextGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        sessionGeneration &+= 1
        return sessionGeneration
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionGeneration == generation
    }

    private func currentTextureId() -> Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return textureId
    }

    private func setTextureId(_ id: Int64?) {
        stateLock.lock()
        textureId = id
        stateLock.unlock()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        // Release the camera and texture when the engine detaches this plugin, so the capture
        // session cannot outlive the engine. Termination is covered by the observer above, but an
        // engine can also be destroyed while the app keeps running, for example in add-to-app.
        releaseCamera()
        releaseTexture()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "state":
            checkPermission(call, result)
        case "request":
            requestPermission(call, result)
        case "start":
            start(call, result)
        case "toggleTorch":
            toggleTorch(result)
        case "setTorchMode":
            setTorchMode(call, result)
        case "getSupportedLenses":
            getSupportedLenses(call, result)
        case "getBestCloseRangeScanningLens":
            getBestCloseRangeScanningLens(call, result)
        case "setScale":
            setScale(call, result)
        case "setFocus":
            setFocus(call, result)
        case "resetScale":
            resetScale(call, result)
        case "pause":
            pause(call, result)
        case "stop":
            stop(call, result)
        case "updateScanWindow":
            updateScanWindow(call, result)
        case "analyzeImage":
            analyzeImage(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }
    
    // FlutterStreamHandler
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
    
    // FlutterTexture
    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()

        guard let buffer else {
            return nil
        }

        return Unmanaged<CVPixelBuffer>.passRetained(buffer)
    }
    
    /// Notifies the texture registry that a new frame is available.
    ///
    /// This is called from ``sampleBufferQueue``, while the Flutter engine is torn down on the
    /// main thread, so the notification is hopped to the main queue to serialize it against that
    /// teardown. `FlutterTextureRegistryRelay` holds its parent weakly, but the engine object
    /// outlives the shell that actually backs the registry, so the weak reference does not guard
    /// against a call that arrives during teardown.
    ///
    /// At most one notification is in flight at a time. The registry always reads the newest
    /// buffer, so queueing one block per captured frame would only pile up redundant work on a
    /// main thread that is already behind.
    private func notifyFrameAvailable(for frameTextureId: Int64) {
        frameNotificationLock.lock()
        if pendingFrameNotification {
            frameNotificationLock.unlock()

            return
        }
        pendingFrameNotification = true
        frameNotificationLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.frameNotificationLock.lock()
            self.pendingFrameNotification = false
            self.frameNotificationLock.unlock()

            // Drop the frame if the engine is going away, or if the texture was released or
            // replaced while this block was queued.
            guard !self.terminating, self.currentTextureId() == frameTextureId else {
                return
            }

            self.registry.textureFrameAvailable(frameTextureId)
        }
    }

    var nextScanTime = 0.0
    var imagesCurrentlyBeingProcessed = false
    
    // Gets called when a new image is added to the buffer
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Ignore invalid texture id.
        guard let activeTextureId = currentTextureId() else {
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        bufferLock.lock()
        latestBuffer = imageBuffer
        bufferLock.unlock()
        notifyFrameAvailable(for: activeTextureId)

        // Measured before the detection check below: that check skips frames at
        // the detection rate, which would otherwise throttle the brightness
        // measurement to a rate that is not its own.
        measureSceneLuminance(imageBuffer)

        let currentTime = Date().timeIntervalSince1970
        let eligibleForScan = currentTime > nextScanTime && !imagesCurrentlyBeingProcessed
        if ((detectionSpeed == DetectionSpeed.normal || detectionSpeed == DetectionSpeed.noDuplicates) && eligibleForScan || detectionSpeed == DetectionSpeed.unrestricted) {
            nextScanTime = currentTime + timeoutSeconds
            imagesCurrentlyBeingProcessed = true
            let bufferToProcess = imageBuffer
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    return
                }

                let buffer = bufferToProcess
                
                var cgImage: CGImage? = nil
                
                let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cgImage)
                
                guard status == kCVReturnSuccess, let currentImage = cgImage else {
                    self.imagesCurrentlyBeingProcessed = false
                    return
                }
                
                let imageRequestHandler = VNImageRequestHandler(cgImage: currentImage)
                
                do {
                    let barcodeRequest: VNDetectBarcodesRequest = VNDetectBarcodesRequest(completionHandler: { [weak self] (request, error) in
                        self?.imagesCurrentlyBeingProcessed = false

                        if error != nil {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !self.terminating, self.textureId != nil else {
                                    return
                                }
                                self.sink?(FlutterError(
                                    code: MobileScannerErrorCodes.BARCODE_ERROR,
                                    message: error?.localizedDescription, details: nil))
                            }
                            return
                        }

                        guard let results: [VNBarcodeObservation] = request.results as? [VNBarcodeObservation] else {
                            return
                        }

                        if results.isEmpty {
                            return
                        }

                        let barcodes: [VNBarcodeObservation] = results.compactMap({ barcode in
                            return barcode
                        })
                        
                        var bytes: FlutterStandardTypedData? = nil
                        
                        if MobileScannerPlugin.returnImage,
                           let imageBytes = currentImage.jpegData(compressionQuality: 0.8) {
                            bytes = FlutterStandardTypedData(bytes: imageBytes)
                        }

                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.terminating, self.textureId != nil else {
                                return
                            }
#if os(iOS)
                            // Always report portrait-ized dimensions on iOS,
                            // matching the convention used in start().
                            // The Dart-side BarcodePainter flips these back
                            // when the device is in landscape orientation.
                            let imageData: [String: Any?] = [
                                "bytes": bytes,
                                "width": Double(min(currentImage.width, currentImage.height)),
                                "height": Double(max(currentImage.width, currentImage.height)),
                            ]
#else
                            let imageData: [String: Any?] = [
                                "bytes": bytes,
                                "width": Double(currentImage.width),
                                "height": Double(currentImage.height),
                            ]
#endif

                            self.sink?([
                                "name": "barcode",
                                "image": imageData,
                                "data": barcodes.map({
                                    $0.toMap(
                                        imageWidth: currentImage.width,
                                        imageHeight: currentImage.height,
                                        scanWindow: self.scanWindow
                                    )
                                }),
                            ])
                        }
                    })

                    if self.symbologies.isEmpty == false {
                        // Add the symbologies the user wishes to support.
                        barcodeRequest.symbologies = self.symbologies
                    }

                    // Set the region of interest to match scanWindow
                    if let scanWindow = self.scanWindow {
                        barcodeRequest.regionOfInterest = scanWindow
                    }

                    try imageRequestHandler.perform([barcodeRequest])
                } catch let error {
                    imagesCurrentlyBeingProcessed = false
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.terminating, self.textureId != nil else {
                            return
                        }
                        self.sink?(FlutterError(
                            code: MobileScannerErrorCodes.BARCODE_ERROR,
                            message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }
    
    func checkPermission(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if #available(iOS 12.0, macOS 10.14, *) {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .notDetermined:
                result(0)
            case .authorized:
                result(1)
            default:
                result(2)
            }
        } else {
            result(1)
        }
    }
    
    func requestPermission(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if #available(iOS 12.0, macOS 10.14, *) {
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { result($0) })
        } else {
            result(0)
        }
    }

    func updateScanWindow(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let argReader = MapArgumentReader(call.arguments as? [String: Any])
        guard let scanWindowData: [CGFloat] = argReader.floatArray(key: "rect") else {
            scanWindow = nil
            result(nil)
            return
        }

        guard scanWindowData.count >= 4 else {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: "Invalid scan window coordinates."))
            return
        }
        
        let left = scanWindowData[0]
        let top = scanWindowData[1]
        let right = scanWindowData[2]
        let bottom = scanWindowData[3]
        
        scanWindow = CGRect(
            x: left,                  // Normalized x-position (left)
            y: 1.0 - bottom,          // Flip Y-axis since Vision uses a different coordinate system
            width: right - left,      // Width (difference between right and left)
            height: bottom - top      // Height (difference between bottom and top)
        )
        
        result(nil)
    }

    private func getVideoOrientation() -> AVCaptureVideoOrientation {
#if os(iOS)
        // Set video orientation to match interface orientation
        // This ensures the camera feed is correctly oriented
        if #available(iOS 13.0, *) {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let orientation = windowScene.interfaceOrientation
                switch orientation {
                case .portrait:
                    return .portrait
                case .portraitUpsideDown:
                    return .portraitUpsideDown
                case .landscapeLeft:
                    return .landscapeLeft
                case .landscapeRight:
                    return .landscapeRight
                default:
                    return .portrait
                }
            }
        }
        return .portrait
#else
        return .portrait
#endif
    }

    func start(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if (isStarting || device != nil || captureSession != nil) {
            result(FlutterError(code: MobileScannerErrorCodes.ALREADY_STARTED_ERROR,
                                message: MobileScannerErrorCodes.ALREADY_STARTED_ERROR_MESSAGE,
                                details: nil))
            return
        }

        let generation = nextGeneration()
        isStarting = true

        let wasPaused = currentTextureId() != nil
        let activeTextureId = currentTextureId() ?? registry.register(self)
        setTextureId(activeTextureId)

        let argReader = MapArgumentReader(call.arguments as? [String: Any])

        let torch:Bool = argReader.bool(key: "torch") ?? false
        let autoTorch:Bool = argReader.bool(key: "autoTorch") ?? false
        let facing:Int = argReader.int(key: "facing") ?? 1
        let lensType:Int = argReader.int(key: "lensType") ?? -1
        let speed:Int = argReader.int(key: "speed") ?? 0
        let timeoutMs:Int = argReader.int(key: "timeout") ?? 0
        let initialZoom: CGFloat? = {
            if let zoomValue = argReader.float(key: "initialZoom") {
                return CGFloat(zoomValue)
            } else {
                return nil
            }
        }()
        symbologies = argReader.toSymbology()
        MobileScannerPlugin.returnImage = argReader.bool(key: "returnImage") ?? false
        reportSceneLuminance = argReader.bool(key: "reportSceneLuminance") ?? false
        nextSceneLuminanceTime = 0

        timeoutSeconds = Double(timeoutMs) / 1000.0
        detectionSpeed = DetectionSpeed(rawValue: speed) ?? .noDuplicates

        // Set the camera to use. In macOS only a front camera is available.
#if os(iOS)
        let targetPosition: AVCaptureDevice.Position = facing == 0 ? .front : .back
#else
        let targetPosition: AVCaptureDevice.Position = .front
#endif
        position = targetPosition

        let deviceVideoOrientation = self.getVideoOrientation()

        sessionQueue.async { [weak self] in
            let cancelledError = FlutterError(
                code: MobileScannerErrorCodes.CAMERA_ERROR,
                message: "Camera start was cancelled.",
                details: nil
            )

            guard let self, self.isCurrentGeneration(generation) else {
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        self.finishFailedStart(
                            result,
                            cancelledError,
                            generation: generation,
                            releaseCreatedTexture: !wasPaused
                        )
                    } else {
                        result(cancelledError)
                    }
                }
                return
            }

            // Open the camera device based on position and lens type
            guard let selectedDevice = MobileScannerCameraSelector.selectCamera(position: targetPosition, lensType: lensType) else {
                let error = FlutterError(
                    code: MobileScannerErrorCodes.NO_CAMERA_ERROR,
                    message: MobileScannerErrorCodes.NO_CAMERA_ERROR_MESSAGE,
                    details: nil
                )
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        self.finishFailedStart(
                            result,
                            error,
                            generation: generation,
                            releaseCreatedTexture: !wasPaused
                        )
                    } else {
                        result(error)
                    }
                }
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()

            // Check the zoom factor at switching from ultra wide camera to wide camera.
            var computedStandardZoomFactor: CGFloat = 1
#if os(iOS)
            if #available(iOS 13.0, *) {
                for (index, actualDevice) in selectedDevice.constituentDevices.enumerated() {
                    if (actualDevice.deviceType != .builtInUltraWideCamera) {
                        if index > 0 && index <= selectedDevice.virtualDeviceSwitchOverVideoZoomFactors.count {
                            computedStandardZoomFactor = CGFloat(truncating: selectedDevice.virtualDeviceSwitchOverVideoZoomFactors[index - 1])
                        }
                        break
                    }
                }
            }
#endif

            // Add device input
            do {
                let input = try AVCaptureDeviceInput(device: selectedDevice)

                if (!(session.canAddInput(input))) {
                    // Commit the open configuration before releasing the camera,
                    // because `stopRunning()` throws an `NSGenericException` inside it.
                    session.commitConfiguration()
                    let error = FlutterError(
                        code: MobileScannerErrorCodes.CAMERA_ERROR,
                        message: MobileScannerErrorCodes.CAMERA_ERROR_CAPTURE_SESSION_INPUT_OCCUPIED_MESSAGE,
                        details: nil
                    )
                    DispatchQueue.main.async { [weak self] in
                        if let self {
                            self.finishFailedStart(
                                result,
                                error,
                                generation: generation,
                                releaseCreatedTexture: !wasPaused
                            )
                        } else {
                            result(error)
                        }
                    }
                    return
                }

                session.addInput(input)
            } catch {
                session.commitConfiguration()
                let flutterError = FlutterError(
                    code: MobileScannerErrorCodes.CAMERA_ERROR,
                    message: error.localizedDescription,
                    details: nil
                )
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        self.finishFailedStart(
                            result,
                            flutterError,
                            generation: generation,
                            releaseCreatedTexture: !wasPaused
                        )
                    } else {
                        result(flutterError)
                    }
                }
                return
            }
            session.sessionPreset = AVCaptureSession.Preset.high

            let videoOutput = AVCaptureVideoDataOutput()

            let format = self.getPreferredVideoFormat(videoOutput: videoOutput)
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: self.sampleBufferQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            if let connection = videoOutput.connections.first {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = deviceVideoOrientation
                }

                if targetPosition == .front && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }

            session.commitConfiguration()

            guard self.isCurrentGeneration(generation) else {
                MobileScannerPlugin.cleanupSession(session, stopRunning: false)
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        self.finishFailedStart(
                            result,
                            cancelledError,
                            generation: generation,
                            releaseCreatedTexture: !wasPaused
                        )
                    } else {
                        result(cancelledError)
                    }
                }
                return
            }

            session.startRunning()

            guard self.isCurrentGeneration(generation) else {
                MobileScannerPlugin.cleanupSession(session, stopRunning: true)
                DispatchQueue.main.async { [weak self] in
                    if let self {
                        self.finishFailedStart(
                            result,
                            cancelledError,
                            generation: generation,
                            releaseCreatedTexture: !wasPaused
                        )
                    } else {
                        result(cancelledError)
                    }
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentGeneration(generation), !self.terminating else {
                    let cleanupQueue = self?.sessionQueue ?? DispatchQueue(label: "dev.steenbakker.mobile_scanner.sessionCleanupQueue", qos: .userInitiated)
                    cleanupQueue.async {
                        MobileScannerPlugin.cleanupSession(session, stopRunning: true)
                    }
                    if let self {
                        self.finishFailedStart(
                            result,
                            cancelledError,
                            generation: generation,
                            releaseCreatedTexture: !wasPaused
                        )
                    } else {
                        result(cancelledError)
                    }
                    return
                }

                self.isStarting = false
                self.captureSession = session
                self.device = selectedDevice
                self.standardZoomFactor = computedStandardZoomFactor

                selectedDevice.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.torchMode), options: .new, context: nil)
#if os(iOS)
                selectedDevice.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.videoZoomFactor), options: [.new, .initial], context: nil)
                // Set up observer to update video orientation when interface orientation changes
                self.setupInterfaceOrientationObserver()
#endif

                let dimensions = CMVideoFormatDescriptionGetDimensions(selectedDevice.activeFormat.formatDescription)

                // Always set the mode, since the device can keep it from an earlier start.
                self.setTorchMode(torch ? .on : autoTorch ? .auto : .off)

                if let initialZoom {
                    do {
                        try self.setScaleInternal(initialZoom)
                    } catch {
                        // Do nothing.
                    }
                }

#if os(iOS)
                // The height and width are swapped because the default video orientation for ios is landscape right, but mobile_scanner operates in portrait mode.
                // When mobile_scanner is opened in landscape mode, the Dart code automatically swaps the width and height parameters back to match the correct orientation.
                let size = ["width": Double(dimensions.height), "height": Double(dimensions.width)]
#else
                let size = ["width": Double(dimensions.width), "height": Double(dimensions.height)]
#endif
                let cameraDirection: Int? = switch(selectedDevice.position) {
                    case .back: 1
                    case .unspecified: nil
                    case .front: 0
                    @unknown default: nil
                }

                let answer: [String : Any?] = [
                    "textureId": activeTextureId,
                    "size": size,
                    "currentTorchState": selectedDevice.hasTorch ? selectedDevice.torchMode.rawValue : -1,
                    "cameraDirection": cameraDirection,
                    "initialDeviceOrientation": deviceVideoOrientation.toOrientationString
                ]

                result(answer)
            }
        }
    }

    /// Get the preferred video format for the given video output.
    private func getPreferredVideoFormat(videoOutput: AVCaptureVideoDataOutput) -> OSType {
        // Define preferred pixel formats in order of preference
        let preferredFormats: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        
        // Get available formats and convert from NSNumber to OSType
        let availableFormats = videoOutput.availableVideoPixelFormatTypes
        let availablePixelFormats = availableFormats.compactMap { ($0 as NSNumber).uint32Value }
        
        // Find the first preferred format that is available
        for format in preferredFormats {
            if availablePixelFormats.contains(format) {
                return format
            }
        }
        
        if let firstAvailable = availablePixelFormats.first {
            return firstAvailable
        }
        
        // Ultimate fallback: use the original default format
        return kCVPixelFormatType_32BGRA
    }

    private func getSupportedLenses(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let argReader = MapArgumentReader(call.arguments as? [String: Any])
        let facing: AVCaptureDevice.Position? = switch argReader.int(key: "facing") {
        case 0?: .front
        case 1?: .back
        default: nil
        }
        result(MobileScannerCameraSelector.getSupportedLenses(facing: facing))
    }

    private func getBestCloseRangeScanningLens(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let argReader = MapArgumentReader(call.arguments as? [String: Any])
        let position: AVCaptureDevice.Position = switch argReader.int(key: "facing") {
        case 0?: .front
        default: .back
        }
        result(MobileScannerCameraSelector.getBestCloseRangeScanningLens(position: position))
    }

    /// Set the torch mode, if the device supports it.
    private func setTorchMode(_ mode: AVCaptureDevice.TorchMode) {
        guard let device = self.device else {
            return
        }

        if (!device.hasTorch || !device.isTorchModeSupported(mode) || device.torchMode == mode) {
            return
        }

        if #available(macOS 15.0, *) {
            if(mode != .off && !device.isTorchAvailable) {
                return
            }
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } catch(_) {
            // Do nothing.
        }
    }

    /// Sets the zoomScale.
    private func setScale(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let scale = call.arguments as? CGFloat else {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.INVALID_ZOOM_SCALE_ERROR_MESSAGE,
                                details: "The invalid zoom scale was nil."))
            return
        }
        do {
            try setScaleInternal(scale)
            result(nil)
        } catch MobileScannerError.zoomWhenStopped {
            result(FlutterError(code: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR,
                                message: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR_MESSAGE,
                                details: nil))
        } catch MobileScannerError.zoomError(let error) {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: error.localizedDescription,
                                details: nil))
        } catch {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: nil))
        }
    }

    /// Reset the zoomScale.
    private func resetScale(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        do {
            try resetScaleInternal()
            result(nil)
        } catch MobileScannerError.zoomWhenStopped {
            result(FlutterError(code: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR,
                                message: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR_MESSAGE,
                                details: nil))
        } catch MobileScannerError.zoomError(let error) {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: error.localizedDescription,
                                details: nil))
        } catch {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: nil))
        }
    }

    /// Set the zoom factor of the camera
    func setScaleInternal(_ scale: CGFloat) throws {
        guard let device = self.device else {
            throw MobileScannerError.zoomWhenStopped
        }

        do {
#if os(iOS)
            try device.lockForConfiguration()
            // Limit to 1.0 scale
            device.videoZoomFactor = getSafeZoomFactor(scale: scale)

            device.unlockForConfiguration()
#endif
        } catch {
            throw MobileScannerError.zoomError(error)
        }
    }
    
    private func setFocus(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let dx = args["dx"] as? CGFloat,
              let dy = args["dy"] as? CGFloat else {
            result(FlutterError(code: MobileScannerErrorCodes.INVALID_FOCUS_POINT,
                                message: MobileScannerErrorCodes.INVALID_FOCUS_POINT_MESSAGE,
                                details: nil))
            return
        }
        let focusPoint = CGPoint(x: dx, y: dy)
        
        do {
            guard let device = self.device else {
                throw MobileScannerError.zoomWhenStopped
            }

#if os(iOS)
            if device.isFocusPointOfInterestSupported {
                do {
                    try device.lockForConfiguration()
                    device.focusPointOfInterest = focusPoint
                    device.focusMode = .autoFocus
                    device.unlockForConfiguration()
                } catch {
                    throw MobileScannerError.zoomError(error)
                }
            }
#endif
        
            result(nil)
        } catch {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: nil))
        }
    }

#if os(iOS)
    /// Set up observer for interface orientation changes
    private func setupInterfaceOrientationObserver() {
        removeInterfaceOrientationObserver()
        if #available(iOS 13.0, *) {
            interfaceOrientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateVideoOrientationFromInterfaceOrientation()
            }
        }
    }

    /// Remove interface orientation observer
    private func removeInterfaceOrientationObserver() {
        if let observer = interfaceOrientationObserver {
            NotificationCenter.default.removeObserver(observer)
            interfaceOrientationObserver = nil
        }
    }

    /// Update video orientation to match current interface orientation
    private func updateVideoOrientationFromInterfaceOrientation() {
        guard let session = captureSession,
              let videoOutput = session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }).first else {
            return
        }

        let newVideoOrientation = getVideoOrientation()

        for connection in videoOutput.connections {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = newVideoOrientation
            }
        }
    }
#endif

    /// Reset the zoom factor of the camera
    func resetScaleInternal() throws {
        guard let device = self.device else {
            throw MobileScannerError.zoomWhenStopped
        }

        do {
#if os(iOS)
            try device.lockForConfiguration()
            device.videoZoomFactor = standardZoomFactor
            device.unlockForConfiguration()
#endif
        } catch {
            throw MobileScannerError.zoomError(error)
        }
    }
    
    func getSafeZoomFactor(scale: CGFloat) -> CGFloat {
        var scaleToUse = scale
#if os(iOS)
        guard let device = self.device else {
            return scaleToUse
        }
        var actualScale = (scale * 4) + 1
        
        // Set a maximum zoom limit of 5x
        actualScale = min(5.0, actualScale)
        
        // Ensure it does not exceed the camera's max zoom capability
        scaleToUse = min(device.activeFormat.videoMaxZoomFactor, actualScale)
#endif
        return scaleToUse
    }
    
    func getScaleFromZoomFactor(actualScale: CGFloat) -> CGFloat {
        return (actualScale - 1) / 4
    }

    private func toggleTorch(_ result: @escaping FlutterResult) {
        guard let device = self.device else {
            result(nil)
            return
        }
        
        if (!device.hasTorch) {
            result(nil)
            return
        }
        
        if #available(macOS 15.0, *) {
            if(!device.isTorchAvailable) {
                result(nil)
                return
            }
        }
        
        var newTorchMode: AVCaptureDevice.TorchMode = device.torchMode
        
        switch(device.torchMode) {
        case AVCaptureDevice.TorchMode.auto:
            if #available(macOS 10.15, *) {
                newTorchMode = device.isTorchActive ? AVCaptureDevice.TorchMode.off : AVCaptureDevice.TorchMode.on
            }
            break;
        case AVCaptureDevice.TorchMode.off:
            newTorchMode = AVCaptureDevice.TorchMode.on
            break;
        case AVCaptureDevice.TorchMode.on:
            newTorchMode = AVCaptureDevice.TorchMode.off
            break;
        default:
            result(nil)
            return;
        }
        
        if (!device.isTorchModeSupported(newTorchMode) || device.torchMode == newTorchMode) {
            result(nil)
            return;
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = newTorchMode
            device.unlockForConfiguration()
        } catch(_) {
            // Do nothing.
        }

        result(nil)
    }

    /// Sets the torch to an absolute state, unlike `toggleTorch`.
    func setTorchMode(_ call: FlutterMethodCall, _ result: FlutterResult) {
        // Off = 0, On = 1. Auto is rejected, because in `.auto` the torch only
        // illuminates once a movie file recording starts, and this session has
        // no recording output.
        let newTorchMode: AVCaptureDevice.TorchMode
        switch (call.arguments as? Int) {
        case 0:
            newTorchMode = AVCaptureDevice.TorchMode.off
        case 1:
            newTorchMode = AVCaptureDevice.TorchMode.on
        default:
            result(FlutterError(code: MobileScannerErrorCodes.SET_TORCH_MODE_ERROR,
                                message: MobileScannerErrorCodes.SET_TORCH_MODE_ERROR_MESSAGE,
                                details: nil))
            return
        }

        guard let device = self.device, device.hasTorch else {
            result(nil)
            return
        }

        if #available(macOS 15.0, *) {
            if (!device.isTorchAvailable) {
                result(nil)
                return
            }
        }

        // Load bearing: `-setTorchMode:` raises an NSInvalidArgumentException
        // for an unsupported mode, and that cannot be caught from Swift.
        if (!device.isTorchModeSupported(newTorchMode) || device.torchMode == newTorchMode) {
            result(nil)
            return
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = newTorchMode
            device.unlockForConfiguration()
        } catch(_) {
            // Do nothing.
        }

        result(nil)
    }

    /// Measures the brightness of the current frame and reports it.
    ///
    /// The measurement is throttled to `sceneLuminanceInterval` and reads only
    /// about `sceneLuminanceSamples` pixels of the buffer that the delegate
    /// already receives, so it adds no image conversion and no camera stream of
    /// its own. This runs on `sampleBufferQueue`, so the subsampling and the
    /// throttle keep CPU work low, and event sink delivery is dispatched to the
    /// main thread.
    private func measureSceneLuminance(_ imageBuffer: CVImageBuffer) {
        if (!reportSceneLuminance) {
            return
        }

        let now = Date().timeIntervalSince1970
        if (now < nextSceneLuminanceTime) {
            return
        }
        nextSceneLuminanceTime = now + sceneLuminanceInterval

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(imageBuffer)
        let isBiPlanar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // Plane 0 of the bi-planar formats is luma, so brightness needs no
        // conversion there. The 32BGRA fallback is converted per sample.
        let baseAddress = isBiPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0)
            : CVPixelBufferGetBaseAddress(imageBuffer)
        let bytesPerRow = isBiPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
            : CVPixelBufferGetBytesPerRow(imageBuffer)
        let width = isBiPlanar
            ? CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
            : CVPixelBufferGetWidth(imageBuffer)
        let height = isBiPlanar
            ? CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
            : CVPixelBufferGetHeight(imageBuffer)

        guard let address = baseAddress, width > 0, height > 0 else {
            return
        }

        let buffer = address.assumingMemoryBound(to: UInt8.self)
        let bytesPerPixel = isBiPlanar ? 1 : 4

        // Step over the frame so that roughly `sceneLuminanceSamples` pixels are
        // read, no matter what resolution the camera picked.
        let step = max(1, Int((Double(width) * Double(height) / Double(sceneLuminanceSamples)).squareRoot()))

        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        var count = 0

        var y = 0
        while y < height {
            let rowOffset = y * bytesPerRow
            var x = 0
            while x < width {
                let index = rowOffset + x * bytesPerPixel
                let luma: Int
                if (isBiPlanar) {
                    luma = Int(buffer[index])
                } else {
                    let b = Int(buffer[index])
                    let g = Int(buffer[index + 1])
                    let r = Int(buffer[index + 2])
                    luma = (r * 299 + g * 587 + b * 114) / 1000
                }

                histogram[luma] += 1
                total += luma
                count += 1
                x += step
            }
            y += step
        }

        if (count == 0) {
            return
        }

        let mean = Double(total) / Double(count) / 255.0
        let p90 = Double(percentile(histogram, count, 0.9)) / 255.0

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminating, self.textureId != nil else {
                return
            }
            self.sink?(["name": "sceneLuminance", "data": ["mean": mean, "p90": p90]])
        }
    }

    /// Returns the `fraction` percentile of the given brightness `histogram`.
    private func percentile(_ histogram: [Int], _ count: Int, _ fraction: Double) -> Int {
        let target = Int((Double(count) * fraction).rounded(.up))
        var seen = 0

        for luma in 0..<histogram.count {
            seen += histogram[luma]
            if (seen >= target) {
                return luma
            }
        }

        return histogram.count - 1
    }

    func pause(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let force = (call.arguments as? Bool) ?? false
        if (!force) {
            if (!isStarting && (paused || stopped)) {
                result(nil)

                return
            }
        }

        releaseCamera {
            result(nil)
        }
    }

    func stop(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let force = (call.arguments as? Bool) ?? false
        if (!isStarting && !paused && stopped && !force) {
            result(nil)

            return
        }
        releaseTexture()
        releaseCamera {
            result(nil)
        }
    }

    /// Clean up a failed or cancelled start on the main thread, then report the error.
    private func finishFailedStart(
        _ result: FlutterResult,
        _ error: FlutterError,
        generation: UInt64,
        releaseCreatedTexture: Bool
    ) {
        if isCurrentGeneration(generation) {
            isStarting = false
            if releaseCreatedTexture {
                releaseTexture()
            }
        }
        result(error)
    }

    private static func cleanupSession(_ session: AVCaptureSession, stopRunning: Bool) {
        if stopRunning {
            session.stopRunning()
        }
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            if let videoOutput = output as? AVCaptureVideoDataOutput {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
            }
            session.removeOutput(output)
        }
    }

    private func releaseCamera(completion: (() -> Void)? = nil) {
        _ = nextGeneration()
        isStarting = false

#if os(iOS)
        removeInterfaceOrientationObserver()
#endif

        let sessionToStop = captureSession
        let deviceToRelease = device

        captureSession = nil
        device = nil

        if let deviceToRelease {
            deviceToRelease.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.torchMode))
#if os(iOS)
            deviceToRelease.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.videoZoomFactor))
#endif
        }

        bufferLock.lock()
        latestBuffer = nil
        bufferLock.unlock()

        guard sessionToStop != nil || completion != nil else {
            return
        }

        sessionQueue.async {
            if let sessionToStop {
                MobileScannerPlugin.cleanupSession(sessionToStop, stopRunning: true)
            }

            if let completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    private func releaseTexture() {
        guard let textureIdToRelease = currentTextureId() else {
            return
        }

        setTextureId(nil)
        registry.unregisterTexture(textureIdToRelease)
    }

    func analyzeImage(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        // The iOS Simulator cannot use some of the GPU features that are required for the Vision API.
        // Thus analyzing images is not supported on the iOS Simulator.
        //
        // See https://forums.developer.apple.com/forums/thread/696714
#if os(iOS) && targetEnvironment(simulator)
        result(FlutterError(
            code: MobileScannerErrorCodes.UNSUPPORTED_OPERATION_ERROR,
            message: MobileScannerErrorCodes.ANALYZE_IMAGE_IOS_SIMULATOR_NOT_SUPPORTED_ERROR_MESSAGE,
            details: nil
        ))
        return
#else
        let argReader = MapArgumentReader(call.arguments as? [String: Any])
        let symbologies:[VNBarcodeSymbology] = argReader.toSymbology()

        guard let filePath: String = argReader.string(key: "filePath") else {
            result(nil)
            return
        }

        let fileUrl = URL(fileURLWithPath: filePath)

        guard let ciImage = CIImage(contentsOf: fileUrl) else {
            result(FlutterError(
                code: MobileScannerErrorCodes.BARCODE_ERROR,
                message: MobileScannerErrorCodes.ANALYZE_IMAGE_NO_VALID_IMAGE_ERROR_MESSAGE,
                details: nil
            ))
            return
        }

        let imageRequestHandler = VNImageRequestHandler(ciImage: ciImage, orientation: CGImagePropertyOrientation.up, options: [:])

        do {
            let barcodeRequest: VNDetectBarcodesRequest = VNDetectBarcodesRequest(
                completionHandler: { [] (request, error) in

                if error != nil {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: MobileScannerErrorCodes.BARCODE_ERROR,
                            message: error?.localizedDescription, details: nil))
                    }
                    return
                }

                guard let barcodes: [VNBarcodeObservation] = request.results as? [VNBarcodeObservation] else {
                    DispatchQueue.main.async {
                        result([
                            "name": "barcode",
                            "data": [],
                        ])
                    }
                    return
                }

                if barcodes.isEmpty {
                    DispatchQueue.main.async {
                        result([
                            "name": "barcode",
                            "data": [],
                        ])
                    }
                    return
                }
                    
                DispatchQueue.main.async {
                    result([
                        "name": "barcode",
                        "data": barcodes.map({ $0.toMap(imageWidth: Int(ciImage.extent.width), imageHeight: Int(ciImage.extent.height), scanWindow: self.scanWindow) }),
                    ])
                }
            })

            if !symbologies.isEmpty {
                // Add the symbologies the user wishes to support.
                barcodeRequest.symbologies = symbologies
            }

            try imageRequestHandler.perform([barcodeRequest])
        } catch let error {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: MobileScannerErrorCodes.BARCODE_ERROR,
                    message: error.localizedDescription, details: nil))
            }
        }
#endif
    }

    // Observer for torch state
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        switch keyPath {
        case #keyPath(AVCaptureDevice.torchMode):
            // Off = 0, On = 1, Auto = 2
            let state = change?[.newKey] as? Int
            let event: [String: Any?] = ["name": "torchState", "data": state]
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminating, self.textureId != nil else {
                    return
                }
                self.sink?(event)
            }
#if os(iOS)
        case #keyPath(AVCaptureDevice.videoZoomFactor):
            if let zoomScale = change?[.newKey] as? CGFloat {
                let scale = getScaleFromZoomFactor(actualScale: zoomScale)

                let event: [String: Any?] = ["name": "zoomScaleState", "data": scale]
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.terminating, self.textureId != nil else {
                        return
                    }
                    self.sink?(event)
                }
            }
#endif
        default:
            break
        }
    }
}

class MapArgumentReader {
    let args: [String: Any]?

    init(_ args: [String: Any]?) {
        self.args = args
    }

    func string(key: String) -> String? {
        return args?[key] as? String
    }

    func int(key: String) -> Int? {
        return (args?[key] as? NSNumber)?.intValue
    }
    
    func float(key: String) -> Float? {
        return (args?[key] as? NSNumber)?.floatValue
    }

    func bool(key: String) -> Bool? {
        return (args?[key] as? NSNumber)?.boolValue
    }

    func stringArray(key: String) -> [String]? {
        return args?[key] as? [String]
    }

    func toSymbology() -> [VNBarcodeSymbology] {
        guard let syms:[Int] = args?["formats"] as? [Int] else {
            return []
        }
        if(syms.contains(0)){
            return []
        }
        var barcodeFormats:[VNBarcodeSymbology] = []
        syms.forEach { id in
            if let bc: VNBarcodeSymbology = VNBarcodeSymbology.fromInt(id) {
                barcodeFormats.append(bc)
            }
        }
        return barcodeFormats
    }

    func floatArray(key: String) -> [CGFloat]? {
        return args?[key] as? [CGFloat]
    }

}

extension CGImage {
    public func jpegData(compressionQuality: CGFloat) -> Data? {
        let mutableData = CFDataCreateMutable(nil, 0)

        let formatHint: CFString
        
        if #available(iOS 14.0, macOS 11.0, *) {
            formatHint = UTType.jpeg.identifier as CFString
        } else {
            formatHint = kUTTypeJPEG
        }

        guard let destination = CGImageDestinationCreateWithData(mutableData!, formatHint, 1, nil) else {
            return nil
        }

        let options: NSDictionary = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ]

        CGImageDestinationAddImage(destination, self, options)

        if !CGImageDestinationFinalize(destination) {
            return nil
        }

        return mutableData as Data?
    }
}

extension VNBarcodeObservation {
    private func distanceBetween(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        return sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2))
    }
    
    /// Map this `VNBarcodeObservation` to a dictionary.
    ///
    /// The `imageWidth` and `imageHeight` indicate the width and height of the input image that contains this observation.
    public func toMap(imageWidth: Int, imageHeight: Int, scanWindow: CGRect?) -> [String: Any?] {

        // Calculate adjusted points based on whether scanWindow is set
        let adjustedTopLeft: CGPoint
        let adjustedTopRight: CGPoint
        let adjustedBottomRight: CGPoint
        let adjustedBottomLeft: CGPoint

        if let scanWindow = scanWindow {
            // When a scanWindow is set, adjust the barcode coordinates to the full image
            func adjustPoint(_ point: CGPoint) -> CGPoint {
                let x = scanWindow.minX + point.x * scanWindow.width
                let y = scanWindow.minY + point.y * scanWindow.height
                return CGPoint(x: x, y: y)
            }

            adjustedTopLeft = adjustPoint(topLeft)
            adjustedTopRight = adjustPoint(topRight)
            adjustedBottomRight = adjustPoint(bottomRight)
            adjustedBottomLeft = adjustPoint(bottomLeft)
        } else {
            // If no scanWindow, use original points (already normalized to the full image)
            adjustedTopLeft = topLeft
            adjustedTopRight = topRight
            adjustedBottomRight = bottomRight
            adjustedBottomLeft = bottomLeft
        }

        // Convert adjusted points from normalized coordinates to image pixel coordinates
        let topLeftX = adjustedTopLeft.x * CGFloat(imageWidth)
        let topRightX = adjustedTopRight.x * CGFloat(imageWidth)
        let bottomRightX = adjustedBottomRight.x * CGFloat(imageWidth)
        let bottomLeftX = adjustedBottomLeft.x * CGFloat(imageWidth)
        let topLeftY = (1 - adjustedTopLeft.y) * CGFloat(imageHeight)
        let topRightY = (1 - adjustedTopRight.y) * CGFloat(imageHeight)
        let bottomRightY = (1 - adjustedBottomRight.y) * CGFloat(imageHeight)
        let bottomLeftY = (1 - adjustedBottomLeft.y) * CGFloat(imageHeight)

        // Calculate the width and height of the barcode based on adjusted coordinates
        let width = distanceBetween(adjustedTopLeft, adjustedTopRight) * CGFloat(imageWidth)
        let height = distanceBetween(adjustedTopLeft, adjustedBottomLeft) * CGFloat(imageHeight)
        var rawBytes: FlutterStandardTypedData? = nil
        var rawPayloadData: FlutterStandardTypedData? = nil
        var displayValue: String? = payloadStringValue

        // QR codes: parse the error-corrected payload bit stream directly.
        // This correctly recovers the original bytes from Byte-mode segments,
        // including non-ASCII content such as UTF-8 encoded text.
        if let qrDescriptor = barcodeDescriptor as? CIQRCodeDescriptor,
           let parsed = BarcodePayloadParser.parseQRPayload(from: qrDescriptor) {
            rawBytes = FlutterStandardTypedData(bytes: parsed)
            if let utf8String = String(data: parsed, encoding: .utf8) {
                displayValue = utf8String
            }
        }

        // Aztec, DataMatrix, PDF417, and linear formats: use the ISO-Latin-1
        // round-trip. Apple Vision decodes raw payload bytes as Latin-1
        // characters in payloadStringValue, so re-encoding back to Latin-1
        // recovers the original bytes for values in the range 0x00–0x7F and
        // 0xA0–0xFF. Bytes in 0x80–0x9F are not recoverable this way. see
        // README for the full platform limitation note.
        if rawBytes == nil, let string = payloadStringValue {
            if let data = string.data(using: .isoLatin1) {
                rawBytes = FlutterStandardTypedData(bytes: data)
                if let utf8String = String(data: data, encoding: .utf8) {
                    displayValue = utf8String
                }
            }
        }

        if #available(iOS 17.0, macOS 14.0, *) {
            if let payloadData = payloadData {
                rawPayloadData = FlutterStandardTypedData(bytes: payloadData)
            }
        }

        // Detect barcode type from payload string value using heuristics
        let barcodeType = payloadStringValue?.detectBarcodeType()

        // On macOS, the front camera image is horizontally mirrored relative to
        // Vision's coordinate labels, so topLeft/topRight (and bottomLeft/bottomRight)
        // are swapped in screen space. Swap them here so that corners[0]→corners[1]
        // points left-to-right in screen space, which is required for correct
        // overlay text angle calculation.
#if os(macOS)
        let corners: [[String: CGFloat]] = [
            ["x": topRightX, "y": topRightY],
            ["x": topLeftX, "y": topLeftY],
            ["x": bottomLeftX, "y": bottomLeftY],
            ["x": bottomRightX, "y": bottomRightY],
        ]
#else
        let corners: [[String: CGFloat]] = [
            ["x": topLeftX, "y": topLeftY],
            ["x": topRightX, "y": topRightY],
            ["x": bottomRightX, "y": bottomRightY],
            ["x": bottomLeftX, "y": bottomLeftY],
        ]
#endif
        let data = [
            // Clockwise, starting from the top-left corner.
            "corners": corners,
            "format": symbology.toInt ?? -1,
            "rawBytes": rawBytes,
            "rawPayloadData": rawPayloadData,
            "rawValue": payloadStringValue,
            "displayValue": displayValue,
            "size": [
                "width": width,
                "height": height,
            ],
            "type": barcodeType,
        ] as [String : Any?]
        return data
    }
}

extension VNBarcodeSymbology {
    static func fromInt(_ mapValue:Int) -> VNBarcodeSymbology? {
        if #available(iOS 15.0, macOS 12.0, *) {
            switch(mapValue){
            case 8:
                return VNBarcodeSymbology.codabar
            case 32768:
                return VNBarcodeSymbology.gs1DataBar
            case 65536:
                return VNBarcodeSymbology.gs1DataBarExpanded
            case 131072:
                return VNBarcodeSymbology.gs1DataBarLimited
            default:
                break
            }
        }
        switch(mapValue){
        case 1:
            return VNBarcodeSymbology.code128
        case 2:
            return VNBarcodeSymbology.code39
        case 4:
            return VNBarcodeSymbology.code93
        case 16:
            return VNBarcodeSymbology.dataMatrix
        case 32:
            return VNBarcodeSymbology.ean13
        case 64:
            return VNBarcodeSymbology.ean8
        case 126:
            return VNBarcodeSymbology.i2of5
        case 127:
            return VNBarcodeSymbology.i2of5Checksum
        case 128:
            return VNBarcodeSymbology.itf14
        case 256:
            return VNBarcodeSymbology.qr
        case 1024:
            return VNBarcodeSymbology.upce
        case 2048:
            return VNBarcodeSymbology.pdf417
        case 4096:
            return VNBarcodeSymbology.aztec
        default:
            return nil
        }
    }

    var toInt: Int? {
        if #available(iOS 15.0, macOS 12.0, *) {
            switch(self){
            case VNBarcodeSymbology.codabar:
                return 8
            case VNBarcodeSymbology.gs1DataBar:
                return 32768
            case VNBarcodeSymbology.gs1DataBarExpanded:
                return 65536
            case VNBarcodeSymbology.gs1DataBarLimited:
                return 131072
            default:
                break
            }
        }
        switch(self){
        case VNBarcodeSymbology.code128:
            return 1
        case VNBarcodeSymbology.code39:
            return 2
        case VNBarcodeSymbology.code93:
            return 4
        case VNBarcodeSymbology.dataMatrix:
            return 16
        case VNBarcodeSymbology.ean13:
            return 32
        case VNBarcodeSymbology.ean8:
            return 64
        case VNBarcodeSymbology.i2of5:
            return 126
        case VNBarcodeSymbology.i2of5Checksum:
            return 127
        case VNBarcodeSymbology.itf14:
            return 128
        case VNBarcodeSymbology.qr:
            return 256
        case VNBarcodeSymbology.upce:
            return 1024
        case VNBarcodeSymbology.pdf417:
            return 2048
        case VNBarcodeSymbology.aztec:
            return 4096
        default:
            return -1
        }
    }
}

extension AVCaptureVideoOrientation {
    var toOrientationString: String {
        switch self {
        case .portrait:
            return "PORTRAIT_UP"
        case .portraitUpsideDown:
            return "PORTRAIT_DOWN"
        case .landscapeLeft:
            return "LANDSCAPE_LEFT"
        case .landscapeRight:
            return "LANDSCAPE_RIGHT"
        default:
            return "PORTRAIT_UP"
        }
    }
}

#if os(iOS)
extension UIDeviceOrientation {
    var toOrientationString: String {
        switch self {
        case .portrait:
            return "PORTRAIT_UP"
        case .portraitUpsideDown:
            return "PORTRAIT_DOWN"
        case .landscapeLeft:
            return "LANDSCAPE_LEFT"
        case .landscapeRight:
            return "LANDSCAPE_RIGHT"
        case .faceUp:
            return "PORTRAIT_UP"
        case .faceDown:
            return "PORTRAIT_DOWN"
        default:
            return "PORTRAIT_UP"
        }
    }
    
    /// Converts UIDeviceOrientation to correct VideoOrientation
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait:
            return .portrait
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
}
#endif
