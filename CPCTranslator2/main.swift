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

struct TokenResponse : Codable {
    var token_type: String
    var expires_in: Int
    var ext_expires_in: Int
    var access_token: String
}

struct TranslationRequest : Codable {
    var data: String
}

struct CPCTranslator2Configuration : Codable {
    var subscription: String
    var region: String
    var jwtClientSecret: String
    var jwtAudience: String
    var jwtClientId: String
    var jwtTenantId: String
    var serverUrl: String
    var useTestOutput: Bool
}

class ConfigurationManager {
    func loadConfiguration() -> CPCTranslator2Configuration {
        var applicationSupportPath = "."
        let paths = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.applicationSupportDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)
        
        if !paths.isEmpty {
            applicationSupportPath = paths.first!
        }
        
        let configJson = try! String(contentsOfFile: "\(applicationSupportPath)/CPCTranslator2/config.json", encoding: .utf8)
        
        return try! JSONDecoder().decode(CPCTranslator2Configuration.self, from: configJson.data(using: .utf8)!)
    }
}

class ApiClient {
    private var _accessToken: String?
    private let _configuration: CPCTranslator2Configuration
    
    init(config: CPCTranslator2Configuration) {
        _accessToken = nil
        _configuration = config
    }
    func getToken() async -> String {
        if _accessToken == nil {
            let secret = _configuration.jwtClientSecret
            let audience = _configuration.jwtAudience
            let clientId = _configuration.jwtClientId
            let grantType = "client_credentials"
            let tenantId = _configuration.jwtTenantId
            let endpoint = URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token")!
            
            var request = URLRequest(url: endpoint)
            
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpMethod = "POST"
            request.httpBody = "client_id=\(clientId)&scope=\(audience)%2F.default&client_secret=\(secret)&grant_type=\(grantType)".data(using: .utf8)!
            
            let session = URLSession.shared
            
            let (data, _) = try! await session.data(for: request)
            
            let decoder = JSONDecoder()
            let decoded_response = try! decoder.decode(TokenResponse.self, from: data)
            
            _accessToken = decoded_response.access_token
        }
        
        return _accessToken!
    }
    
    func sendTranslationData(translationData: String) async {
        let token = await getToken()
        let body = TranslationRequest(data: translationData)
        let url = URL(string: "\(_configuration.serverUrl)/translation")!
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.httpBody = try! JSONEncoder().encode(body)
        
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let session = URLSession.shared
        
        let (_, _) = try! await session.data(for: request)
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
    //private let _outfile: AVAudioFile
    
    init(destinationStream: SPXPushAudioInputStream) {
        _engine = AVAudioEngine()
        _sampleRate = 16000
        _bufferSize = 2048
        _conversionQueue = DispatchQueue(label: "conversionQueue")
        _recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: _sampleRate, channels: 1, interleaved: false)!
        _formatConverter = AVAudioConverter(from: _engine.inputNode.outputFormat(forBus: 0), to: _recordingFormat)!
        _destinationStream = destinationStream
        
        //print("inputNode: \(_engine.inputNode.outputFormat(forBus: 0).sampleRate)")
//        _outfile = try! AVAudioFile(forWriting: URL(fileURLWithPath: "/Users/nfm/recording.caf"), settings: _engine.inputNode.inputFormat(forBus: 0).settings, commonFormat: _recordingFormat.commonFormat, interleaved: false)
        
        _engine.inputNode.installTap(onBus: 0, bufferSize: _bufferSize, format: _engine.inputNode.outputFormat(forBus: 0), block: processAudioBuffer)
        
        let player = AVAudioPlayerNode()
        _engine.attach(player)
        _engine.connect(player, to: _engine.mainMixerNode, format: _engine.mainMixerNode.outputFormat(forBus: 0))
        
        _engine.prepare()
    }
    
    func processAudioBuffer(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        _conversionQueue.async {
            let outputBufferCapacity = AVAudioFrameCount(buffer.duration * self._recordingFormat.sampleRate)

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
    private var _translationConfig: SPXSpeechTranslationConfiguration
    private var _pushStream: SPXPushAudioInputStream
    private var _audioConfig: SPXAudioConfiguration
    private var _recognizer: SPXTranslationRecognizer
    private var _publishingQueue: DispatchQueue
    private let _configuration: CPCTranslator2Configuration
    private let _audioEngine: AudioEngine
    private let _apiClient: ApiClient
    
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
                    print("TRANSLATED: \(translation.value)")
                }
//                print("TRANSLATED [\(translation.key)]: \(translation.value)")
//
//                _publishingQueue.async {
//                    Task {
//                        await self._apiClient.sendTranslationData(translationData: "\(translation.value)")
//                    }
//                }
            
        }
        else if evt.result.reason == SPXResultReason.noMatch {
            let reason = try! SPXNoMatchDetails(fromNoMatch: evt.result)
            
            print("Unknown")
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
    
    init(config: CPCTranslator2Configuration, apiClient: ApiClient) {
        _configuration = config
        _apiClient = apiClient
        
        _publishingQueue = DispatchQueue(label: "publishingQueue")
        
        _translationConfig = try! SPXSpeechTranslationConfiguration(subscription: _configuration.subscription, region: _configuration.region)
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
  
let configManager = ConfigurationManager()
let config = configManager.loadConfiguration()

if config.useTestOutput {
    while true {
        let time = Date()
        print("TRANSLATED: this is a test message sent at \(time)")
        sleep(3)
    }
}
else {
    let client = ApiClient(config: config)
    let translator = SpeechTranslator(config: config, apiClient: client)
    
    print("Starting translation...")
    
    translator.startTranslating()
    
    let _ = readLine()
    
    translator.stopTranslating()
}
