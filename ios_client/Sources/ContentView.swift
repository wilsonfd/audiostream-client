//
//  ContentView.swift
//  AudioStreamClient
//

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = StreamManager()
    @State private var ip: String = UserDefaults.standard.string(forKey: "pc_ip") ?? ""
    @State private var port: String = "13579"
    @State private var showSettings = false
    @State private var latencyMode: StreamManager.LatencyMode = {
        if let s = UserDefaults.standard.string(forKey: "latency_mode"),
           let m = StreamManager.LatencyMode(rawValue: s) { return m }
        return .balanced
    }()

    var body: some View {
        ZStack {
            // 背景渐变，随状态变化
            LinearGradient(
                gradient: Gradient(colors: bgColors),
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: phaseKey)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerButton
                statusBlock
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                ip: $ip, port: $port, latencyMode: $latencyMode,
                onApply: { manager.latencyMode = latencyMode }
            )
        }
        .onAppear { manager.latencyMode = latencyMode }
    }

    // MARK: 顶栏
    private var topBar: some View {
        HStack {
            Text("PC 音频接收器")
                .font(.headline.weight(.semibold))
                .foregroundColor(.white)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
        }
    }

    // MARK: 中心大按钮
    private var centerButton: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                // 连接中：旋转弧
                if manager.phase == .connecting {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .frame(width: 180, height: 180)
                        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }
                } else {
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 6)
                        .frame(width: 180, height: 180)
                }

                // 已连接：脉冲光环
                if manager.phase == .connected {
                    Circle().fill(Color.white.opacity(0.18))
                        .frame(width: 180, height: 180)
                        .scaleEffect(pulse ? 1.18 : 1.0)
                        .opacity(pulse ? 0.0 : 0.5)
                        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } }
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)

                VStack(spacing: 10) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundColor(iconColor)
                        .contentTransition(.symbolEffect(.replace))
                    Text(buttonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(iconColor)
                }
            }
            .frame(width: 220, height: 220)
        }
        .buttonStyle(.plain)
        .disabled(manager.phase == .connecting)
    }

    @State private var spin = false
    @State private var pulse = false

    // MARK: 状态
    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(statusTitle)
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            Text(manager.statusText)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            if let meta = manager.metaText {
                Text(meta)
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.top, 2)
            }
        }
        .padding(.top, 36)
    }

    // MARK: 计算属性
    private var phaseKey: Int {
        switch manager.phase {
        case .disconnected: return 0
        case .connecting: return 1
        case .waiting: return 2
        case .connected: return 3
        }
    }
    private var bgColors: [Color] {
        switch manager.phase {
        case .disconnected:
            return [Color(red: 0.30, green: 0.34, blue: 0.42), Color(red: 0.18, green: 0.20, blue: 0.26)]
        case .connecting:
            return [Color(red: 0.16, green: 0.45, blue: 0.95), Color(red: 0.10, green: 0.28, blue: 0.62)]
        case .waiting:
            return [Color(red: 0.14, green: 0.55, blue: 0.80), Color(red: 0.08, green: 0.30, blue: 0.55)]
        case .connected:
            return [Color(red: 0.16, green: 0.70, blue: 0.45), Color(red: 0.06, green: 0.45, blue: 0.30)]
        }
    }
    private var buttonIcon: String {
        switch manager.phase {
        case .disconnected: return "power"
        case .connecting: return "ellipsis"
        case .waiting: return "waveform"
        case .connected: return "speaker.wave.2.fill"
        }
    }
    private var buttonTitle: String {
        switch manager.phase {
        case .disconnected: return "连接"
        case .connecting: return "连接中"
        case .waiting: return "等待音频"
        case .connected: return "播放中"
        }
    }
    private var iconColor: Color {
        switch manager.phase {
        case .disconnected: return Color(red: 0.30, green: 0.34, blue: 0.42)
        case .connecting: return Color(red: 0.16, green: 0.45, blue: 0.95)
        case .waiting: return Color(red: 0.10, green: 0.45, blue: 0.70)
        case .connected: return Color(red: 0.10, green: 0.55, blue: 0.35)
        }
    }
    private var statusTitle: String {
        switch manager.phase {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接电脑"
        case .waiting: return "已连接"
        case .connected: return "正在播放"
        }
    }

    private func handleTap() {
        if manager.phase == .disconnected {
            UserDefaults.standard.set(ip, forKey: "pc_ip")
            manager.connect(host: ip, port: Int(port) ?? 13579)
        } else {
            manager.disconnect()
        }
    }
}

// MARK: 设置页
struct SettingsView: View {
    @Binding var ip: String
    @Binding var port: String
    @Binding var latencyMode: StreamManager.LatencyMode
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("电脑连接") {
                    HStack {
                        Image(systemName: "network")
                            .foregroundColor(.blue)
                        TextField("PC 局域网 IP", text: $ip)
                            .keyboardType(.numbersAndPunctuation)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.blue)
                        TextField("端口", text: $port)
                            .keyboardType(.numberPad)
                    }
                }

                Section("延迟模式") {
                    Picker("延迟模式", selection: $latencyMode) {
                        ForEach(StreamManager.LatencyMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("使用说明") {
                    settingRow("wifi", "手机与电脑连同一个 WiFi")
                    settingRow("moon.stars", "锁屏/切后台可继续播放")
                    settingRow("music.note", "与其他 App 声音混音共存")
                    settingRow("xmark.circle", "上滑彻底杀掉 App 才会停止")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onApply()
                        UserDefaults.standard.set(latencyMode.rawValue, forKey: "latency_mode")
                        dismiss()
                    }
                }
            }
        }
    }

    private func settingRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 22)
            Text(text).font(.subheadline)
        }
    }
}
