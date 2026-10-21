# 不用 Mac 也能出 IPA 的完整流程

整体链路：
```
你的 Windows 本仓库 --push--> GitHub Actions (macOS 虚拟机) --> 自动产出 unsigned.ipa
                                                                    |
                                                                    v
                                              Windows 上 Sideloadly 用你的 Apple ID 重签 --> 装到 iPhone
```

你全程不用碰 Mac，不用装 Xcode。

---

## 第一步：把代码推到 GitHub

1. 注册/登录 GitHub，新建一个仓库（**建议 Public**，Actions 免费额度无限；Private 仓库每月 2000 分钟，Mac runner 按 10 倍计费，够 build 200 次左右）。
2. 把整个 `audio-stream/` 目录 push 上去，目录结构要保持这样：

```
<repo root>/
├── .github/workflows/build-ipa.yml
└── ios_client/
    ├── project.yml
    └── Sources/
        ├── AudioStreamClientApp.swift
        ├── ContentView.swift
        └── StreamManager.swift
```

push 上去后，GitHub 仓库页 → Actions 标签 → 会看到 "Build unsigned IPA" workflow 自动跑起来（约 3-5 分钟）。

3. 跑完点进那次 run → 底部 **Artifacts** 区块 → 下载 `AudioStreamClient-unsigned` → 解压得到 `AudioStreamClient-unsigned.ipa`。

> 第一次跑如果 Actions 没自动触发：手动点 Actions 页左边的 workflow → 右上角 "Run workflow" 按钮。

---

## 第二步：Windows 上用 Sideloadly 自签名安装

### 准备
1. 装 [iTunes](https://www.apple.com/itunes/download/win64)（Win11 也可装 "Apple Devices"）——Sideloadly 需要它带的 Apple 驱动。
2. 下载 [Sideloadly](https://sideloadly.io/) 并安装。
3. iPhone 用数据线连电脑，手机上弹"信任此电脑"点信任。

### 装 App
1. 打开 Sideloadly。
2. 把下载到的 `AudioStreamClient-unsigned.ipa` 拖进 Sideloadly 窗口。
3. 上面选好你的 iPhone。
4. Apple Account 一栏填你自己的 Apple ID（**免费账号就行，不需要 99 刀开发者**）。
5. 点 **Start**。第一次会让你输 Apple ID 密码（或 App-Specific Password，如果开了两步验证）。
6. 等一两分钟，装完手机桌面会出现 App 图标。

### 首次启动信任证书
iPhone：**设置 → 通用 → VPN与设备管理** → 点你刚那个 Apple ID 对应的开发者证书 → 信任。

### 注意
- **免费 Apple ID 签出来的 App 7 天后过期**，到期 App 打不开。解决办法：手机再连电脑跑一次 Sideloadly 重签，或者装 [AltStore](https://altstore.io/) 让它在 WiFi 下自动 7 天一续。
- 要长期不过期，就得花 $99/年买 Apple 开发者账号，签一次管一年。自用不折腾建议直接免费账号 + 7 天重签。

---

## 第三步：用
1. 电脑双击 `AudioStreamServer.exe`。
2. 手机打开 "PC 音频接收器"，填电脑 IP（exe 启动后控制台打印的那个，比如 `192.168.1.30`）。
3. 点连接，完事。锁屏、切后台、开别的 App 都不影响。
