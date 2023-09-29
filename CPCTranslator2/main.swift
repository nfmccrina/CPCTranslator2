//
//  main.swift
//  CPCTranslator
//
//  Created by Nathan McCrina on 9/28/23.
//

import Foundation
import AVFoundation
import MicrosoftCognitiveServicesSpeech

extension AVAudioPCMBuffer {
    func data() -> Data {
        var nBytes = 0
        nBytes = Int(self.frameLength * (self.format.streamDescription.pointee.mBytesPerFrame))
        var range: NSRange = NSRange()
        range.location = 0
        range.length = nBytes
        let buffer = NSMutableData()
        buffer.replaceBytes(in: range, withBytes: (self.int16ChannelData![0]))
        return buffer as Data
    }
    
    var duration: TimeInterval {
        format.sampleRate > 0 ? .init(frameLength) / format.sampleRate : 0
    }
}

class AudioEngine {
    private let _engine: AVAudioEngine
    private var _conversionQueue: DispatchQueue
    private let _formatConverter: AVAudioConverter
    private let _recordingFormat: AVAudioFormat
    private let _destinationStream: SPXPushAudioInputStream
    private let _sampleRate: Double
    private let _bufferSize: AVAudioFrameCount
    
    init(destinationStream: SPXPushAudioInputStream) {
        _engine = AVAudioEngine()
        _sampleRate = 16000
        _bufferSize = 2048
        _conversionQueue = DispatchQueue(label: "conversionQueue")
        _recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: _sampleRate, channels: 1, interleaved: false)!
        _formatConverter = AVAudioConverter(from: _engine.inputNode.outputFormat(forBus: 0), to: _recordingFormat)!
        _destinationStream = destinationStream
        
        _engine.inputNode.installTap(onBus: 0, bufferSize: _bufferSize, format: _engine.inputNode.inputFormat(forBus: 0), block: processAudioBuffer)
        
        let player = AVAudioPlayerNode()
        _engine.attach(player)
        _engine.connect(player, to: _engine.mainMixerNode, format: _engine.mainMixerNode.outputFormat(forBus: 0))
        
        _engine.prepare()
    }
    
    func processAudioBuffer(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        _conversionQueue.async {
            let outputBufferCapacity = AVAudioFrameCount(buffer.frameCapacity)

            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self._recordingFormat, frameCapacity: outputBufferCapacity) else {
                print("Failed to create new pcm buffer")
                return
            }

            pcmBuffer.frameLength = outputBufferCapacity

            var error: NSError? = nil
            let inputBlock: AVAudioConverterInputBlock = {inNumPackets, outStatus in
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                return buffer
            }

            self._formatConverter.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)

            if error != nil {
                print(error!.localizedDescription)
            }
            else {
                self._destinationStream.write(pcmBuffer.data())
            }
        }
    }
    
    func start() {
        do {
            try _engine.start()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func stop() {
        _engine.stop()
        _engine.inputNode.removeTap(onBus: 0)
    }
}

class SpeechTranslator {
    private let _sub: String
    private let _region: String
    private var _translationConfig: SPXSpeechTranslationConfiguration
    private var _pushStream: SPXPushAudioInputStream
    private var _audioConfig: SPXAudioConfiguration
    private var _recognizer: SPXTranslationRecognizer
    private let _audioEngine: AudioEngine
    
    func handleSessionStarted(recognizer: SPXRecognizer, evt: SPXSessionEventArgs) {
        print("Session Started")
    }
    
    func handleSessionStopped(recognizer: SPXRecognizer, evt: SPXSessionEventArgs) {
        print("Session Stopped")
    }
    
    func handleRecognizing(recognizer: SPXRecognizer, evt: SPXTranslationRecognitionEventArgs) {
        if evt.result.reason == SPXResultReason.translatingSpeech {
            for translation in evt.result.translations {
                print("Translating [\(translation.key)]: \(translation.value)")
            }
        }
    }
    
    func handleRecognized(recognizer: SPXRecognizer, evt: SPXTranslationRecognitionEventArgs) {
        if evt.result.reason == SPXResultReason.translatedSpeech {
            for translation in evt.result.translations {
                print("TRANSLATED [\(translation.key)]: \(translation.value)")
            }
        }
        else if evt.result.reason == SPXResultReason.noMatch {
            let reason = try! SPXNoMatchDetails(fromNoMatch: evt.result)
            
            print("NOMATCH: Reason=\(reason.reason)")
        }
    }
    
    func handleCanceled(recognizer: SPXRecognizer, evt: SPXTranslationRecognitionCanceledEventArgs) {
        print("CANCELED: Reason=\(evt.reason)")
        
        if evt.reason == SPXCancellationReason.error {
            print("CANCELED: ErrorCode=\(evt.errorCode)\nCANCELED: ErrorDetails=\(evt.errorDetails ?? "n/a")")
        }
    }
    
    func startTranslating() {
        _audioEngine.start()
        
        do {
            try _recognizer.startContinuousRecognition()
        } catch {
            print(error.localizedDescription)
            stopTranslating()
        }
    }
    
    func stopTranslating() {
        do {
            try _recognizer.stopContinuousRecognition()
        } catch {
            print(error.localizedDescription)
        }
        
        _audioEngine.stop()
    }
    
    init() {
        _sub = "0d3c308c3e4146bf9d03d04a46984922"
        _region = "centralus"
        
        _translationConfig = try! SPXSpeechTranslationConfiguration(subscription: _sub, region: _region)
        _translationConfig.speechRecognitionLanguage = "en-US"
        
        _pushStream = SPXPushAudioInputStream()
        _audioEngine = AudioEngine(destinationStream: _pushStream)
        _audioConfig = SPXAudioConfiguration(streamInput: _pushStream)!
        _recognizer = try! SPXTranslationRecognizer(_translationConfig)
        
        _recognizer.addTargetLanguage("uk")
        
        _recognizer.addSessionStartedEventHandler(handleSessionStarted)
        _recognizer.addSessionStoppedEventHandler(handleSessionStopped)
        _recognizer.addRecognizingEventHandler(handleRecognizing)
        _recognizer.addRecognizedEventHandler(handleRecognized)
        _recognizer.addCanceledEventHandler(handleCanceled)
    }
}


//var outfile = try! AVAudioFile(forWriting: URL(fileURLWithPath: "/Users/nfm/recording.caf"), settings: inputFormat.settings, commonFormat: inputFormat.commonFormat, interleaved: false)



let translator = SpeechTranslator()

print("Starting translation...")

translator.startTranslating()

let _ = readLine()

translator.stopTranslating()
