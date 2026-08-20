@preconcurrency import AVFoundation
import CoreVideo
import Flutter
import Foundation
import VideoToolbox

private enum VideoTranscodeError: LocalizedError {
  case invalidArguments
  case missingInput
  case missingVideoTrack
  case cannotAddVideoOutput
  case cannotAddVideoInput
  case cannotAddAudioOutput
  case cannotAddAudioInput
  case cannotStartReader
  case cannotStartWriter
  case encodingFailed
  case invalidOutput

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "The video encoder received invalid arguments."
    case .missingInput:
      return "The selected video file is unavailable."
    case .missingVideoTrack:
      return "The selected file has no video track."
    case .cannotAddVideoOutput, .cannotAddVideoInput:
      return "The video encoder could not configure the video track."
    case .cannotAddAudioOutput, .cannotAddAudioInput:
      return "The video encoder could not configure the audio track."
    case .cannotStartReader:
      return "The selected video could not be read."
    case .cannotStartWriter:
      return "The encoded video could not be created."
    case .encodingFailed:
      return "The video could not be encoded."
    case .invalidOutput:
      return "The video encoder created an invalid file."
    }
  }
}

final class VideoTranscodeBridge: NSObject, FlutterPlugin {
  private static let channelName = "juliatalk/video-transcoder"
  private static let videoBitRate = 3_080_000
  private static let audioBitRate = 92_000
  private static let audioSampleRate = 44_100

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(VideoTranscodeBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "transcode" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let inputPath = arguments["input_path"] as? String,
      !inputPath.isEmpty
    else {
      result(Self.flutterError(VideoTranscodeError.invalidArguments))
      return
    }

    Task { @MainActor in
      do {
        result(try await Self.transcode(inputPath: inputPath))
      } catch {
        result(Self.flutterError(error))
      }
    }
  }

  private static func transcode(inputPath: String) async throws -> [String: Any] {
    let inputURL = URL(fileURLWithPath: inputPath)

    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw VideoTranscodeError.missingInput
    }

    let asset = AVURLAsset(url: inputURL)
    let tracks = try await asset.load(.tracks)
    guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
      throw VideoTranscodeError.missingVideoTrack
    }

    let naturalSize = try await videoTrack.load(.naturalSize)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
    let formatDescriptions = try await videoTrack.load(.formatDescriptions)
    let outputURL = try makeOutputURL()
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

    let videoOutput = AVAssetReaderTrackOutput(
      track: videoTrack,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ]
    )
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
      throw VideoTranscodeError.cannotAddVideoOutput
    }
    reader.add(videoOutput)

    var compressionProperties: [String: Any] = [
      AVVideoAverageBitRateKey: videoBitRate,
      AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
      AVVideoAllowFrameReorderingKey: true,
    ]
    if nominalFrameRate > 0 {
      compressionProperties[AVVideoExpectedSourceFrameRateKey] = Int(
        nominalFrameRate.rounded()
      )
    }

    var videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(naturalSize.width.rounded()),
      AVVideoHeightKey: Int(naturalSize.height.rounded()),
      AVVideoCompressionPropertiesKey: compressionProperties,
    ]
    if let sourceDescription = formatDescriptions.first,
       let colorProperties = colorProperties(from: sourceDescription) {
      videoSettings[AVVideoColorPropertiesKey] = colorProperties
    }

    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      throw VideoTranscodeError.cannotAddVideoInput
    }
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: videoSettings
    )
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = preferredTransform
    videoInput.performsMultiPassEncodingIfSupported = false
    guard writer.canAdd(videoInput) else {
      throw VideoTranscodeError.cannotAddVideoInput
    }
    writer.add(videoInput)

    var audioOutput: AVAssetReaderOutput?
    var audioInput: AVAssetWriterInput?

    if let sourceAudioTrack = tracks.first(where: { $0.mediaType == .audio }) {
      let configuredAudioOutput = AVAssetReaderAudioMixOutput(
        audioTracks: [sourceAudioTrack],
        audioSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: audioSampleRate,
          AVNumberOfChannelsKey: 2,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
      )
      configuredAudioOutput.alwaysCopiesSampleData = false
      guard reader.canAdd(configuredAudioOutput) else {
        throw VideoTranscodeError.cannotAddAudioOutput
      }
      reader.add(configuredAudioOutput)

      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: audioSampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: audioBitRate,
      ]
      guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
        throw VideoTranscodeError.cannotAddAudioInput
      }
      let configuredAudioInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: audioSettings
      )
      configuredAudioInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(configuredAudioInput) else {
        throw VideoTranscodeError.cannotAddAudioInput
      }
      writer.add(configuredAudioInput)
      audioOutput = configuredAudioOutput
      audioInput = configuredAudioInput
    }

    guard writer.startWriting() else {
      throw writer.error ?? VideoTranscodeError.cannotStartWriter
    }
    guard reader.startReading() else {
      writer.cancelWriting()
      throw reader.error ?? VideoTranscodeError.cannotStartReader
    }
    writer.startSession(atSourceTime: .zero)

    try await appendSamples(
      reader: reader,
      writer: writer,
      videoOutput: videoOutput,
      videoInput: videoInput,
      audioOutput: audioOutput,
      audioInput: audioInput
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
    guard
      let fileSize = attributes[.size] as? NSNumber,
      fileSize.intValue > 0
    else {
      throw VideoTranscodeError.invalidOutput
    }

    let outputAsset = AVURLAsset(url: outputURL)
    let outputDuration = try await outputAsset.load(.duration)
    let transformedSize = naturalSize.applying(preferredTransform)

    return [
      "local_path": outputURL.path,
      "file_name": outputURL.lastPathComponent,
      "mime_type": "video/mp4",
      "size_bytes": fileSize.intValue,
      "width": Int(abs(transformedSize.width).rounded()),
      "height": Int(abs(transformedSize.height).rounded()),
      "duration_ms": Int((outputDuration.seconds * 1_000).rounded()),
    ]
  }

  private static func makeOutputURL() throws -> URL {
    let cacheDirectory = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = cacheDirectory.appendingPathComponent(
      "video-uploads",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")
  }

  private static func colorProperties(
    from description: CMFormatDescription
  ) -> [String: Any]? {
    guard
      let extensions = CMFormatDescriptionGetExtensions(description)
        as? [String: Any]
    else {
      return nil
    }

    var properties: [String: Any] = [:]
    let mappings: [(CFString, String)] = [
      (kCVImageBufferColorPrimariesKey, AVVideoColorPrimariesKey),
      (kCVImageBufferTransferFunctionKey, AVVideoTransferFunctionKey),
      (kCVImageBufferYCbCrMatrixKey, AVVideoYCbCrMatrixKey),
    ]

    for (sourceKey, destinationKey) in mappings {
      if let value = extensions[sourceKey as String] {
        properties[destinationKey] = value
      }
    }

    return properties.isEmpty ? nil : properties
  }

  private static func appendSamples(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    videoOutput: AVAssetReaderOutput,
    videoInput: AVAssetWriterInput,
    audioOutput: AVAssetReaderOutput?,
    audioInput: AVAssetWriterInput?
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let group = DispatchGroup()
      let errorLock = NSLock()
      var encodingError: Error?

      func record(_ error: Error) {
        errorLock.lock()
        if encodingError == nil {
          encodingError = error
          reader.cancelReading()
        }
        errorLock.unlock()
      }

      group.enter()
      let videoQueue = DispatchQueue(label: "juliatalk.video-encoder.video")
      var videoFinished = false
      videoInput.requestMediaDataWhenReady(on: videoQueue) {
        guard !videoFinished else { return }

        while videoInput.isReadyForMoreMediaData {
          guard let sample = videoOutput.copyNextSampleBuffer() else {
            videoFinished = true
            videoInput.markAsFinished()
            group.leave()
            return
          }
          guard videoInput.append(sample) else {
            videoFinished = true
            videoInput.markAsFinished()
            record(writer.error ?? VideoTranscodeError.encodingFailed)
            group.leave()
            return
          }
        }
      }

      if let audioOutput, let audioInput {
        group.enter()
        let audioQueue = DispatchQueue(label: "juliatalk.video-encoder.audio")
        var audioFinished = false
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
          guard !audioFinished else { return }

          while audioInput.isReadyForMoreMediaData {
            guard let sample = audioOutput.copyNextSampleBuffer() else {
              audioFinished = true
              audioInput.markAsFinished()
              group.leave()
              return
            }
            guard audioInput.append(sample) else {
              audioFinished = true
              audioInput.markAsFinished()
              record(writer.error ?? VideoTranscodeError.encodingFailed)
              group.leave()
              return
            }
          }
        }
      }

      group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
        errorLock.lock()
        let resolvedError = encodingError
        errorLock.unlock()

        if let resolvedError {
          writer.cancelWriting()
          continuation.resume(throwing: resolvedError)
          return
        }
        if reader.status == .failed {
          writer.cancelWriting()
          continuation.resume(
            throwing: reader.error ?? VideoTranscodeError.encodingFailed
          )
          return
        }

        writer.finishWriting {
          if writer.status == .completed {
            continuation.resume()
          } else {
            continuation.resume(
              throwing: writer.error ?? VideoTranscodeError.encodingFailed
            )
          }
        }
      }
    }
  }

  private static func flutterError(_ error: Error) -> FlutterError {
    FlutterError(
      code: "video_transcode_failed",
      message: error.localizedDescription,
      details: nil
    )
  }
}
