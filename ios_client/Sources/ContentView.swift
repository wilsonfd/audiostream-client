//
//  ContentView.swift
//  AudioStreamClient
//

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = StreamManager()
    @State private var ip: String = UserDefaults.standard.string(forKey: "pc_ip") ?? ""
    @State private var port: String = "13579"
    @State private var latencyMode: StreamManager.LatencyMode = {
        if let s = UserDefaults.standard.string(forKey: "latency_mode"),
           let m = StreamManager.LatencyMode(rawValue: s) { return m }
        return .balanced
    }()

    var body: some View {
        NavigationView {
            Form {
                Section("连接") {
                    TextField("PC 局域网 IP", text: $ip)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    Button(manager.isConnected ? "断开" : "连接") {
                        if manager.isConnected {
                            manager.disconnect()
                        } else {
                            UserDefaults.standard.set(ip, forKey: "pc_ip")
                            manager.connect(host: ip, port: Int(port) ?? 13579)
                        }
                    }
                    .foregroundColor(manager.isConnected ? .red : .accentColor)

                    Picker("延迟模式", selection: $latencyMode) {
                        ForEach(StreamManager.LatencyMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .onChange(of: latencyMode) { new in
                        manager.latencyMode = new
                        UserDefaults.standard.set(new.rawValue, forKey: "latency_mode")
                    }
                    .onAppear { manager.latencyMode = latencyMode }
                }

                Section("状态") {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(manager.statusText).foregroundColor(.secondary)
                    }
                    if let meta = manager.metaText {
                        HStack {
                            Text("音频格式")
                            Spacer()
                            Text(meta).foregroundColor(.secondary)
                        }
                    }
                }

                Section("说明") {
                    Text("""
                    • 手机和电脑必须连同一个 WiFi
                    • 后台/锁屏后会继续播放（需在 Xcode 开启 Background Modes -> Audio）
                    • 本 App 与其他音频 App 混音共存，不会抢占它们的声音
                    • 上滑杀掉 App 才会停止（iOS 系统限制）
                    """)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("PC 音频接收器")
        }
    }
}
