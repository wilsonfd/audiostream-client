//
//  StreamManager.swift
//  AudioStreamClient
//
//  核心：TCP 接收 PCM，AVAudioEngine 播放。
//  - AVAudioSession: .playback + .mixWithOthers （不打断其他 App 声音）
//  - Background Modes 开启 audio 后，锁屏/切后台继续播
//

import Foundation
import Network
import AVFoundation

class StreamManager: ObservableObject {
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var metaText: String? = nil

    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var targetFormat: AVAudioFormat?
    private var prebufferBytes: Int = 0       // 已预缓冲字节数
    private let prebufferTargetBytes: Int     // 开机前预缓冲 ~100ms
    private var receiveQueue = DispatchQueue(label: "audio.recv")
    private var started = false

    init() {
        // 默认 48k/16bit/stereo，约 100ms = 48000*2*2*0.1 ≈ 19200 字节
        self.prebufferTargetBytes = 48000 * 2 * 2 / 10
        configureAudioSession()
    }

    // MARK: - Audio Session
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            // 耳机/外放路由变化时不主动打断，保持混音
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
        } catch {
            DispatchQueue.main.async { self.statusText = "音频会话失败: \(error.localizedDescription)" }
        }
    }

    @objc private func handleRouteChange(note: Notification) {
        // 插拔耳机等路由变化时不重启流，继续播放即可
    }

    // MARK: - Connect
    func connect(host: String, port: Int) {
        disconnect()
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            statusText = "IP 或端口无效"
            return
        }
        statusText = "连接中..."
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .setup: self?.statusText = "准备..."
                case .waiting(let err): self?.statusText = "等待: \(err.localizedDescription)"
                case .prestarting: self?.statusText = "连接中..."
                case .ready:
                    self?.isConnected = true
                    self?.statusText = "已连接，等待音频..."
                    self?.receiveHeader()
                case .failed(let err):
                    self?.isConnected = false
                    self?.statusText = "失败: \(err.localizedDescription)"
                    self?.teardownEngine()
                case .cancelled:
                    self?.isConnected = false
                    self?.statusText = "已断开"
                    self?.teardownEngine()
                @unknown default: break
                }
            }
        }
        conn.start(queue: receiveQueue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        teardownEngine()
        DispatchQueue.main.async {
            self.isConnected = false
            self.statusText = "未连接"
            self.metaText = nil
        }
    }

    // MARK: - Header
    private func receiveHeader() {
        // 先读 4 字节大端长度
        connection?.receive(minimumLength: 4, maximumLength: 4,
                           completion: { [weak self] maybeData, _, maybeErr in
            guard let self = self else { return }
            guard let data = maybeData, data.count == 4, maybeErr == nil else {
                self.fail("读握手头失败")
                return
            }
            let len = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            self.connection?.receive(minimumLength: len, maximumLength: len,
                                    completion: { meta, _, _, err in
                guard let meta = meta, err == nil else { self.fail("读握手 JSON 失败"); return }
                self.handleMeta(data: meta)
            })
        })
    }

    private func handleMeta(data: Data) {
        do {
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let rate = obj["rate"] as! Double
            let channels = obj["channels"] as! Int
            let width = obj["width"] as! Int
            DispatchQueue.main.async {
                self.metaText = "\(Int(rate)) Hz / \(channels)ch / \(width*8)bit"
            }
            setupEngine(rate: rate, channels: channels, width: width)
            receivePCM()
        } catch {
            fail("握手解析失败: \(error)")
        }
    }

    // MARK: - Engine
    private func setupEngine(rate: Double, channels: Int, width: Int) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            fail("不支持的音频格式")
            return
        }
        self.targetFormat = fmt

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
            self.engine = engine
            self.playerNode = player
            self.started = false
            self.prebufferBytes = 0
            player.play()
        } catch {
            fail("引擎启动失败: \(error.localizedDescription)")
        }
    }

    private func teardownEngine() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        targetFormat = nil
        started = false
        prebufferBytes = 0
    }

    // MARK: - Receive PCM
    private func receivePCM() {
        // 每次收一段，多大都行（TCP 流式）
        connection?.receive(minimumLength: 200, maximumLength: 8192,
                            completion: { [weak self] data, _, _, err in
            guard let self = self else { return }
            if let err = err {
                DispatchQueue.main.async { self.statusText = "接收结束: \(err.localizedDescription)" }
                self.disconnect()
                return
            }
            guard let data = data, !data.isEmpty else { return }
            self.enqueue(data: data)
            self.receivePCM()
        })
    }

    private func enqueue(data: Data) {
        guard let fmt = targetFormat,
              let player = playerNode,
              let engine = engine else { return }

        // 启动前先攒够约 100ms 缓冲，避免一开播就 underrun
        if !started {
            prebufferBytes += data.count
            if prebufferBytes < prebufferTargetBytes { return }
            started = true
        }

        // 按帧切片调度
        let frameSize = Int(fmt.streamDescription.pointee.mBytesPerFrame)
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let frames = min(remaining / frameSize, 8192)  // 单次最多调度 8192 帧
            guard frames > 0 else { break }
            let bytes = frames * frameSize
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { break }
            buf.frameLength = AVAudioFrameCount(frames)
            data.subdata(in: offset..<offset+bytes).withUnsafeBytes { raw in
                buf.int16ChannelData?.pointee.initialize(
                    fromBuffer: raw.bindMemory(to: Int16.self).baseAddress!,
                    count: frames * Int(fmt.channelCount)
                )
            }
            player.scheduleBuffer(buf, completionHandler: nil)
            offset += bytes
        }
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async {
            self.statusText = msg
            self.isConnected = false
        }
        teardownEngine()
        connection?.cancel()
        connection = nil
    }
}
