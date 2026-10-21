//
//  StreamManager.swift
//  AudioStreamClient
//
//  UDP 低延迟接收：
//  - 发 HELLO 注册，PC 推 [META] / [AUDIO(seq+PCM)]
//  - 序列号 jitter buffer，乱序/丢包补静音，缓冲膨胀自动跳帧，延迟固定
//  - AVAudioSession .playback + .mixWithOthers，后台/锁屏继续播
//

import Foundation
import Network
import AVFoundation

class StreamManager: ObservableObject {
    enum Phase {
        case disconnected
        case connecting
        case connected
        // 已连接但还没收到音频
        case waiting
    }
    @Published var phase: Phase = .disconnected
    @Published var isConnected = false
    @Published var statusText = "未连接"
    @Published var metaText: String? = nil

    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var targetFormat: AVAudioFormat?
    private var receiveQueue = DispatchQueue(label: "audio.recv")
    private var helloTimer: Timer?

    // 每个 UDP 包的帧数（由 PC meta 告知，默认 480=10ms）
    private var packetFrames: Int = 240
    private var frameSize: Int = 4

    // jitter buffer
    private var jitter = [UInt32: Data]()
    private let jitterLock = NSLock()
    private var baseSeq: UInt32? = nil
    private var expectedSeq: UInt32 = 0
    private var primed = false
    private var stopping = false
    private var prebufferPackets: Int = 10

    enum LatencyMode: String, CaseIterable {
        case low = "极低延迟 (15ms)"
        case balanced = "平衡 (50ms)"
        case stable = "高稳定 (150ms)"
        // 5ms 一个包（PC 端 PACKET_FRAMES=240 @48k）
        var prebufferPackets: Int {
            switch self {
            case .low:      return 3    // 15ms
            case .balanced: return 10   // 50ms
            case .stable:   return 30   // 150ms
            }
        }
        // 允许缓冲额外堆积的包数，超过就跳帧
        var maxExtraPackets: Int {
            switch self {
            case .low:      return 3
            case .balanced: return 6
            case .stable:   return 15
            }
        }
    }
    var latencyMode: LatencyMode = .balanced {
        didSet {
            prebufferPackets = latencyMode.prebufferPackets
            maxExtraPackets = latencyMode.maxExtraPackets
        }
    }
    private var maxExtraPackets: Int = 8
    private var epoch: UInt64 = 0

    init() {
        configureAudioSession()
    }

    // MARK: Audio Session
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            // 降低系统音频 IO 缓冲，进一步压低延迟（5ms，设备可能取最接近的支持值）
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification, object: nil)
        } catch {
            DispatchQueue.main.async { self.statusText = "音频会话失败: \(error.localizedDescription)" }
        }
    }

    @objc private func handleRouteChange(note: Notification) {}

    // MARK: Connect (UDP)
    func connect(host: String, port: Int) {
        disconnect()
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            statusText = "IP 或端口无效"
            phase = .disconnected
            return
        }
        phase = .connecting
        statusText = "连接中..."
        let params = NWParameters.udp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 只处理"当前"连接的状态；旧连接 cancel 后的回调不能误清新连接
                guard self.connection === conn else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.phase = .waiting
                    self.statusText = "已连接，等待音频..."
                    self.startHello()
                    self.receiveLoop()
                case .failed(let err):
                    self.statusText = "失败: \(err.localizedDescription)"
                    self.isConnected = false
                    self.phase = .disconnected
                    self.teardown()
                case .cancelled:
                    self.statusText = "已断开"
                    self.isConnected = false
                    self.phase = .disconnected
                    self.teardown()
                default: break
                }
            }
        }
        conn.start(queue: receiveQueue)
    }

    private func startHello() {
        helloTimer?.invalidate()
        sendHello()
        helloTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendHello()
        }
    }

    private func sendHello() {
        connection?.send(content: Data("HELLO".utf8), completion: .contentProcessed { _ in })
    }

    func disconnect() {
        helloTimer?.invalidate()
        helloTimer = nil
        let old = connection
        connection = nil
        old?.cancel()
        // 立即在主线程重置 UI，按钮马上可点
        isConnected = false
        phase = .disconnected
        statusText = "未连接"
        metaText = nil
        // 立刻把旧引擎引用捕获走并清空，新连接用全新对象；
        // 真正的 stop() 丢后台队列，避免阻塞主线程卡界面
        stopping = true
        let oldEngine = engine
        let oldPlayer = playerNode
        engine = nil
        playerNode = nil
        targetFormat = nil
        jitterLock.lock()
        jitter.removeAll()
        baseSeq = nil
        primed = false
        jitterLock.unlock()
        receiveQueue.async {
            oldPlayer?.stop()
            oldEngine?.stop()
        }
    }

    private func teardown() {
        stopping = true
        helloTimer?.invalidate()
        helloTimer = nil
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        targetFormat = nil
        jitterLock.lock()
        jitter.removeAll()
        baseSeq = nil
        primed = false
        jitterLock.unlock()
    }

    // MARK: Receive
    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, err in
            guard let self = self else { return }
            if let err = err {
                DispatchQueue.main.async { self.statusText = "接收结束: \(err.localizedDescription)" }
                self.disconnect()
                return
            }
            if let data = data, !data.isEmpty {
                self.parseDatagram(data)
            }
            self.receiveLoop()
        }
    }

    private func parseDatagram(_ d: Data) {
        guard d.count > 1 else { return }
        let tag = d[d.startIndex]
        if tag == 0x01 {
            // META: [0x01][len UInt16 BE][JSON]
            guard d.count >= 3 else { return }
            let len = Int(d[d.startIndex+1]) << 8 | Int(d[d.startIndex+2])
            guard d.count >= 3 + len else { return }
            let json = d.subdata(in: 3..<(3+len))
            handleMeta(json)
        } else if tag == 0x02 {
            // AUDIO: [0x02][seq UInt32 BE][PCM]
            guard d.count >= 6 else { return }
            let seq = d.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let pcm = d.subdata(in: 5..<d.count)
            handleAudio(seq: seq, pcm: pcm)
        }
    }

    private func handleMeta(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = obj["rate"] as? Double,
              let channels = obj["channels"] as? Int else { return }
        let pf = obj["packet_frames"] as? Int ?? 480
        DispatchQueue.main.async {
            self.metaText = "\(Int(rate)) Hz / \(channels)ch / 16bit"
        }
        // 收到 meta 才设置引擎（只设一次）
        if targetFormat == nil {
            setupEngine(rate: rate, channels: channels, packetFrames: pf)
        }
    }

    // MARK: Engine
    private func setupEngine(rate: Double, channels: Int, packetFrames: Int) {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                     channels: AVAudioChannelCount(channels), interleaved: true) else {
            fail("不支持的音频格式")
            return
        }
        targetFormat = fmt
        self.packetFrames = packetFrames
        self.frameSize = channels * 2
        prebufferPackets = latencyMode.prebufferPackets
        maxExtraPackets = latencyMode.maxExtraPackets

        jitterLock.lock()
        jitter.removeAll()
        baseSeq = nil
        primed = false
        stopping = false
        jitterLock.unlock()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            self.engine = engine
            self.playerNode = player
            DispatchQueue.main.async { self.statusText = "已连接，等待音频..." }
        } catch {
            fail("引擎启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: Jitter
    private func handleAudio(seq: UInt32, pcm: Data) {
        jitterLock.lock()
        if baseSeq == nil {
            baseSeq = seq
            expectedSeq = seq
        }
        // 比当前播放位置还旧的迟到包直接丢弃
        if (expectedSeq &- seq) & 0x80000000 == 0 && seq < expectedSeq {
            jitterLock.unlock()
            return
        }
        jitter[seq] = pcm

        if !primed {
            if jitter.count >= prebufferPackets {
                primed = true
                jitterLock.unlock()
                DispatchQueue.main.async {
                    self.phase = .connected
                    self.statusText = "已连接，播放中"
                }
                primePlayback()
                return
            }
        }
        jitterLock.unlock()
    }

    private func primePlayback() {
        guard let player = playerNode else { return }
        // 先排好 prebufferPackets 个缓冲，形成初始抗抖动队列
        for _ in 0..<prebufferPackets {
            scheduleNext()
        }
        player.play()
    }

    // 拉取下一个该播放的包；缺失就补静音
    private func scheduleNext() {
        guard !stopping, let fmt = targetFormat, let player = playerNode else { return }

        var pcm: Data? = nil
        jitterLock.lock()
        // 缓冲膨胀处理：积压超过阈值时，直接跳到接近最新的位置，丢弃旧包，延迟立刻拉回
        if jitter.count > prebufferPackets + maxExtraPackets,
           let newestSeq = jitter.keys.max() {
            let jumpTo = newestSeq &- UInt32(prebufferPackets)
            if jumpTo >= expectedSeq {
                for k in Array(jitter.keys) where k < jumpTo {
                    jitter[k] = nil
                }
                expectedSeq = jumpTo
            }
        }
        pcm = jitter[expectedSeq]
        if pcm != nil { jitter[expectedSeq] = nil }
        expectedSeq = expectedSeq &+ 1
        jitterLock.unlock()

        let frames = packetFrames
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        if let pcm = pcm, pcm.count == frames * frameSize {
            buf.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { raw in
                if let src = raw.bindMemory(to: Int16.self).baseAddress {
                    buf.int16ChannelData?.pointee.initialize(from: src, count: frames * Int(fmt.channelCount))
                }
            }
        } else {
            // 丢包/静音：零填充
            buf.frameLength = AVAudioFrameCount(frames)
            if let ch = buf.int16ChannelData {
                for c in 0..<Int(fmt.channelCount) {
                    memset(ch[c], 0, frames * MemoryLayout<Int16>.size)
                }
            }
        }
        player.scheduleBuffer(buf, completionHandler: { [weak self] in
            self?.scheduleNext()
        })
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async {
            self.statusText = msg
            self.isConnected = false
        }
        receiveQueue.async { self.teardown() }
        connection?.cancel()
        connection = nil
    }
}
