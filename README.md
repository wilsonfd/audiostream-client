# 局域网 PC → iPhone 音频串流（自用版）

只传声音，不传屏幕。手机和电脑连同一个 WiFi，电脑当服务器，手机当音箱。
- 后台 / 锁屏继续播 ✅
- 与其他 App 声音混音共存，不抢麦 ✅
- 杀掉 App 才停（iOS 系统限制，无解）

```
audio-stream/
├── pc_server/               # Windows 端
│   ├── stream_server.py
│   └── requirements.txt
└── ios_client/
    └── AudioStreamClient/   # 拖进 Xcode 工程的 3 个 Swift 文件
        ├── AudioStreamClientApp.swift
        ├── ContentView.swift
        └── StreamManager.swift
```

---

## 一、Windows PC 端

```powershell
cd pc_server
pip install -r requirements.txt
python stream_server.py
```

跑起来后控制台会打印类似：

```
[采集设备] 扬声器 (Realtek(R) Audio)
==================================================
  采样率 48000 Hz / 2ch / 16bit
  监听端口 13579
  本机局域网 IP: 192.168.3.25
==================================================
```

第一次跑如果 Windows 防火墙弹窗，**允许专用网络**。
把手机连到和电脑同一个 WiFi，然后在 iOS 端填上面那个 IP。

播放任何声音（B站、网易云、游戏）都会被实时抓到手机上。

---

## 二、iOS 端（Xcode 自签名）

### 1. 新建工程
Xcode → New Project → iOS → App，名字随意（比如 `AudioStreamClient`），Interface 选 **SwiftUI**，Language 选 **Swift**。

### 2. 拖入源码
把 `ios_client/AudioStreamClient/` 里这 3 个文件拖进工程（勾选 "Copy items if needed"）：
- `AudioStreamClientApp.swift`
- `ContentView.swift`
- `StreamManager.swift`

> 注意：Xcode 模板自带的 `AudioStreamClientApp.swift` 和 `ContentView.swift` 会和这两个重名，直接覆盖即可。

### 3. 开两个 Capability（关键，不开就没法后台播）
1. 左侧项目导航点蓝色工程图标 → TARGETS → 选你的 App → **Signals & Capabilities** 标签
2. 点 **+ Capability** → 加 **Background Modes**
3. 勾选 ✅ **Audio, AirPlay, and Picture in Picture**

不开这个，一锁屏就断流。

### 4. 自签名跑
1. 连手机，信任开发者证书
2. Team 选你的个人 Apple ID（Signing & Capabilities 里自动管理签名）
3. 选你的真机，⌘R 编译运行

首次在手机上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书。

---

## 三、使用
1. 电脑先跑 `python stream_server.py`
2. 手机 App 里填电脑 IP（PC 端控制台打印的那个），点连接
3. 状态变 "已连接" 后，电脑上放什么手机就出什么声
4. 直接锁屏 / 切到微信 / 开网易云，声音都继续，互不打断

---

## 四、排错

| 现象 | 原因 |
|---|---|
| 手机一直连不上 | 手机和电脑不在同一 WiFi；或 Windows 防火墙拦了 13579 端口 |
| 连上了但没声音 | 手机音量没开；或者系统输出设备不对（PC 脚本抓的是**默认播放设备**，确保你想听的声音是从默认扬声器出的） |
| 锁屏就断 | 没开 Background Modes → Audio |
| 一开播就爆音/卡顿 | 启动前预缓冲 100ms 不够，把 `StreamManager.swift` 里 `prebufferTargetBytes` 调大到 `48000*2*2/5`（200ms） |
| 延迟太大 | 局域网通常 50~150ms 起步，这是 TCP + 100ms 预缓冲的代价；嫌大可以把预缓冲调到 `/20`（50ms）试试 |

---

## 五、技术原理（一句话）
PC 用 WASAPI loopback 抓系统输出 → 裸 16bit PCM 走 TCP 推给手机 → iOS 用 `AVAudioEngine + AVAudioPlayerNode` 播，音频会话设成 `.playback + .mixWithOthers`，所以既能后台驻留又不和别的 App 抢声道。
