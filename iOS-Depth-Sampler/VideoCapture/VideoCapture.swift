//
//  VideoCapture.swift
//
//  Created by Shuichi Tsutsumi on 4/3/16.
//  Copyright © 2016 Shuichi Tsutsumi. All rights reserved.
//

import AVFoundation
import Foundation


struct VideoSpec {
    var fps: Int32?
    var size: CGSize?
}

typealias ImageBufferHandler = (CVPixelBuffer, CMTime, CVPixelBuffer?) -> Void
typealias SynchronizedDataBufferHandler = (CVPixelBuffer, AVDepthData?, AVMetadataObject?) -> Void

extension AVCaptureDevice {
    func printDepthFormats() {
        formats.forEach { (format) in
            let depthFormats = format.supportedDepthDataFormats
            if depthFormats.count > 0 {
                print("format: \(format), supported depth formats: \(depthFormats)")
            }
        }
    }
}

class VideoCapture: NSObject {

    private let captureSession = AVCaptureSession()
    private var videoDevice: AVCaptureDevice!
    private var videoConnection: AVCaptureConnection!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private let dataOutputQueue = DispatchQueue(label: "com.shu223.dataOutputQueue")

    var imageBufferHandler: ImageBufferHandler?
    var syncedDataBufferHandler: SynchronizedDataBufferHandler?

    // プロパティで保持しておかないとdelegate呼ばれない
    // AVCaptureDepthDataOutputはプロパティで保持しなくても大丈夫（CaptureSessionにaddOutputするからだと思う）
    private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer!
    
    // プロパティに保持しておかなくてもOKだが、AVCaptureSynchronizedDataCollectionからデータを取り出す際にあると便利
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    
    private var mutableData = Data()
    private var count = 0
    private lazy var calibrationDataFileURL: URL! = {
        let documentPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last!
        let fileURL = URL(fileURLWithPath: documentPath).appendingPathComponent("calibrationdata.txt")
        try? FileManager.default.removeItem(at: fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            if !FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil) {
                print("Failed to create the log file: \(fileURL)!")
                return nil // To trigger crash.
            }
        }
        return fileURL
    }()
    private lazy var lensDistortionLookupTableDirectory: URL! = {
        let documentPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last!
        let fileURL = URL(fileURLWithPath: documentPath).appendingPathComponent("lensDistortionLookupTable")
        try? FileManager.default.removeItem(at: fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
//            if !FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil) {
//                print("Failed to create the log file: \(fileURL)!")
//                return nil // To trigger crash.
//            }
            try? FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true, attributes: nil)
        }
        return fileURL
    }()
    
    private var fileHandle1: FileHandle?
    private var fileHandle2: FileHandle?
    private lazy var ioQueue: DispatchQueue = {
        return DispatchQueue(label: "ioQueue")
    }()
    
    init(cameraType: CameraType, preferredSpec: VideoSpec?, previewContainer: CALayer?)
    {
        super.init()
        
//        ioQueue.async { [weak self] in
//            if let path = self?.lensDistortionLookupTableDirectory {
//                try? FileManager.default.removeItem(at: path)
//            }
//        }
        fileHandle1 = try? FileHandle(forUpdating: calibrationDataFileURL)
//        fileHandle2 = try? FileHandle(forUpdating: lensDistortionLookupTableFileURL)
        
        captureSession.beginConfiguration()
        
        // inputPriorityだと深度とれない
        captureSession.sessionPreset = AVCaptureSession.Preset.photo
        
        setupCaptureVideoDevice(with: cameraType)
        
        // setup preview
        if let previewContainer = previewContainer {
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.frame = previewContainer.bounds
            previewLayer.contentsGravity = CALayerContentsGravity.resizeAspectFill
            previewLayer.videoGravity = .resizeAspectFill
            previewContainer.insertSublayer(previewLayer, at: 0)
            self.previewLayer = previewLayer
        }
        
        // setup outputs
        do {
            // video output
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
//            videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
            guard captureSession.canAddOutput(videoDataOutput) else { fatalError() }
            captureSession.addOutput(videoDataOutput)
            videoConnection = videoDataOutput.connection(with: .video)

            // depth output
            guard captureSession.canAddOutput(depthDataOutput) else { fatalError() }
            captureSession.addOutput(depthDataOutput)
//            depthDataOutput.setDelegate(self, callbackQueue: dataOutputQueue)
            depthDataOutput.isFilteringEnabled = false
            guard let connection = depthDataOutput.connection(with: .depthData) else { fatalError() }
            connection.isEnabled = true
            
            // metadata output
            guard captureSession.canAddOutput(metadataOutput) else { fatalError() }
            captureSession.addOutput(metadataOutput)
            if metadataOutput.availableMetadataObjectTypes.contains(.face) {
                metadataOutput.metadataObjectTypes = [.face]
            }

            
            // synchronize outputs
            dataOutputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput, metadataOutput])
            dataOutputSynchronizer.setDelegate(self, queue: dataOutputQueue)
        }
        
        setupConnections(with: cameraType)
        
        captureSession.commitConfiguration()
    }
    
    private func setupCaptureVideoDevice(with cameraType: CameraType) {
        
        videoDevice = cameraType.captureDevice()
        print("selected video device: \(String(describing: videoDevice))")
        
        videoDevice.selectDepthFormat()

        captureSession.inputs.forEach { (captureInput) in
            captureSession.removeInput(captureInput)
        }
        let videoDeviceInput = try! AVCaptureDeviceInput(device: videoDevice)
        guard captureSession.canAddInput(videoDeviceInput) else { fatalError() }
        captureSession.addInput(videoDeviceInput)
    }
    
    private func setupConnections(with cameraType: CameraType) {
        videoConnection = videoDataOutput.connection(with: .video)!
        let depthConnection = depthDataOutput.connection(with: .depthData)
        switch cameraType {
        case .front:
            videoConnection.isVideoMirrored = true
            depthConnection?.isVideoMirrored = true
        default:
            break
        }
        videoConnection.videoOrientation = .portrait
        depthConnection?.videoOrientation = .portrait
    }
    
    func startCapture() {
        print("\(self.classForCoder)/" + #function)
        if captureSession.isRunning {
            print("already running")
            return
        }
        captureSession.startRunning()
    }
    
    func stopCapture() {
        print("\(self.classForCoder)/" + #function)
        if !captureSession.isRunning {
            print("already stopped")
            return
        }
        captureSession.stopRunning()
        ioQueue.async { [weak self] in
            self?.fileHandle1?.closeFile()
            self?.fileHandle2?.closeFile()
        }
    }
    
    func resizePreview() {
        if let previewLayer = previewLayer {
            guard let superlayer = previewLayer.superlayer else {return}
            previewLayer.frame = superlayer.bounds
        }
    }
    
    func changeCamera(with cameraType: CameraType) {
        let wasRunning = captureSession.isRunning
        if wasRunning {
            captureSession.stopRunning()
        }
        captureSession.beginConfiguration()

        setupCaptureVideoDevice(with: cameraType)
        setupConnections(with: cameraType)
        
        captureSession.commitConfiguration()
        
        if wasRunning {
            captureSession.startRunning()
        }
    }

    func setDepthFilterEnabled(_ enabled: Bool) {
        depthDataOutput.isFilteringEnabled = enabled
    }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//        print("\(self.classForCoder)/" + #function)
    }
    
    // synchronizer使ってる場合は呼ばれない
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let imageBufferHandler = imageBufferHandler, connection == videoConnection
        {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { fatalError() }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            imageBufferHandler(imageBuffer, timestamp, nil)
        }
    }
}

extension VideoCapture: AVCaptureDepthDataOutputDelegate {
    
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection, reason: AVCaptureOutput.DataDroppedReason) {
        print("\(self.classForCoder)/\(#function)")
    }
    
    // synchronizer使ってる場合は呼ばれない
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        print("\(self.classForCoder)/\(#function)")
    }
}

extension VideoCapture: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        guard !syncedVideoData.sampleBufferWasDropped else {
            print("dropped video:\(syncedVideoData)")
            return
        }
        let videoSampleBuffer = syncedVideoData.sampleBuffer

        let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData
        var depthData = syncedDepthData?.depthData
        if let syncedDepthData = syncedDepthData, syncedDepthData.depthDataWasDropped {
            print("dropped depth:\(syncedDepthData)")
            depthData = nil
        }
//        print("--->depthData: \(depthData)")
        let calibrationData = depthData?.cameraCalibrationData
//        print("timestamp: \(syncedVideoData.timestamp.seconds * 1000), \(calibrationData!.desc)")
        let log = "timestamp: \(syncedVideoData.timestamp.seconds * 1000), \(calibrationData!.desc)\n"
//        print("--->data: \(calibrationData!.lensDistortionLookupTable!)")
        let fileURL = lensDistortionLookupTableDirectory.appendingPathComponent("\(syncedVideoData.timestamp.seconds * 1000).txt")
        ioQueue.async { [weak self] in
            if let data = log.data(using: .utf8) {
                self?.fileHandle1?.seekToEndOfFile()
                self?.fileHandle1?.write(data)
            }
            if let data = calibrationData?.lensDistortionLookupTable {
//                self?.fileHandle2?.seekToEndOfFile()
//                self?.fileHandle2?.write("\ntimestamp: \(syncedVideoData.timestamp.seconds * 1000), ".data(using: .utf8)!)
//                self?.fileHandle2?.seekToEndOfFile()
//                self?.fileHandle2?.write(data)
//                self?.fileHandle2?.closeFile()
//                self?.fileHandle2 = nil
                
                try? data.write(to: fileURL)
            }
        }
//        print("--->intrinsic: \(calibrationData!.intrinsicMatrix)")
//        print("--->extrinsic: \(calibrationData!.extrinsicMatrix)")
//        if count == 3 {
//            try? self.mutableData.write(to: self.filePath)
//        }
//        mutableData.append(log.data(using: .utf8)!)
//        mutableData.append(calibrationData!.lensDistortionLookupTable!)
//        count += 1
        
        

        // 顔のある位置のしきい値を求める
        let syncedMetaData = synchronizedDataCollection.synchronizedData(for: metadataOutput) as? AVCaptureSynchronizedMetadataObjectData
        var face: AVMetadataObject? = nil
        if let firstFace = syncedMetaData?.metadataObjects.first {
            face = videoDataOutput.transformedMetadataObject(for: firstFace, connection: videoConnection)
        }
        guard let imagePixelBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { fatalError() }

        syncedDataBufferHandler?(imagePixelBuffer, depthData, face)
    }
}

extension AVCameraCalibrationData {
    var desc: String {
//        let dataString1: String
//        if let table = lensDistortionLookupTable, let string = String(data: table, encoding: .utf32) {
//            dataString1 = string
//        } else {
//            dataString1 = ""
//        }
        
        var res = ""
        res += "intrinsicMatrix: \(intrinsicMatrix), "
        res += "intrinsicMatrixReferenceDimensions: \(intrinsicMatrixReferenceDimensions), "
        res += "extrinsicMatrix: \(extrinsicMatrix), "
        res += "pixelSize: \(pixelSize), "
        res += "lensDistortionCenter: \(lensDistortionCenter)"
//        res += "lensDistortionLookupTable: \(dataString1)"
//        res += "inverseLensDistortionLookupTable: \(inverseLensDistortionLookupTable ?? Data())"
        return res
    }
}
