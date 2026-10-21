# -*- coding: utf-8 -*-
"""
Windows PC 端：抓取系统默认播放设备的 loopback 音频，通过 TCP 推送给局域网内的 iOS 客户端。
运行：python stream_server.py
依赖：pip install -r requirements.txt
"""
import json
import socket
import struct
import threading
import queue
import sys

import pyaudiowpatch as pyaudio

HOST = "0.0.0.0"
PORT = 13579

# 每次从音频循环里读的帧数；240 帧 * 16bit * 2ch = 960 字节，TCP 单包安全
CHUNK = 240

clients_lock = threading.Lock()
clients = []  # list of (conn, addr)


def broadcast(data: bytes):
    """把一段 PCM 数据发给所有已连接客户端；发送失败的踢掉。"""
    dead = []
    with clients_lock:
        for conn, addr in clients:
            try:
                conn.sendall(data)
            except OSError:
                dead.append((conn, addr))
        for item in dead:
            try:
                clients.remove(item)
            except ValueError:
                pass
    for conn, addr in dead:
        print(f"[断开] {addr}", flush=True)
        try:
            conn.close()
        except OSError:
            pass


def accept_loop(srv: socket.socket, header: bytes):
    """接受新客户端：先握手发头部，再丢进 client 列表。"""
    while True:
        try:
            conn, addr = srv.accept()
        except OSError:
            return
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            conn.sendall(header)
        except OSError:
            conn.close()
            continue
        with clients_lock:
            clients.append((conn, addr))
        print(f"[接入] {addr}  当前在线 {len(clients)} 台", flush=True)


def pick_loopback_device(p: pyaudio.PyAudio):
    """选系统默认输出设备对应的 WASAPI loopback。"""
    wasapi_info = p.get_host_api_info_by_type(pyaudio.paWASAPI)
    default_out = p.get_device_info_by_index(wasapi_info["defaultOutputDevice"])
    if not default_out.get("isLoopbackDevice", False):
        for lb in p.get_loopback_device_info_generator():
            if default_out["name"] in lb["name"]:
                default_out = lb
                break
    print(f"[采集设备] {default_out['name']}", flush=True)
    return default_out


def main():
    p = pyaudio.PyAudio()
    dev = pick_loopback_device(p)

    # 跟设备原生格式走，避免重采样
    rate = int(dev["defaultSampleRate"])
    channels = min(2, int(dev["maxInputChannels"]))
    fmt = pyaudio.paInt16
    width = p.get_sample_size(fmt)

    # 握手头：4 字节大端长度 + JSON{rate, channels, width}
    meta = json.dumps({"rate": rate, "channels": channels, "width": width}).encode("utf-8")
    header = struct.pack(">I", len(meta)) + meta

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(4)

    # 打印本机 IP 方便手机连
    ips = []
    for info in socket.getaddrinfo(socket.gethostname(), PORT, socket.AF_INET):
        ip = info[4][0]
        if not ip.startswith("127."):
            ips.append(ip)
    print("=" * 50, flush=True)
    print(f"  采样率 {rate} Hz / {channels}ch / {width*8}bit", flush=True)
    print(f"  监听端口 {PORT}", flush=True)
    print(f"  本机局域网 IP: {', '.join(ips)}", flush=True)
    print("  在 iOS 端输入上面任一 IP 即可连接（手机需和电脑同一 WiFi）", flush=True)
    print("=" * 50, flush=True)

    threading.Thread(target=accept_loop, args=(srv, header), daemon=True).start()

    q: queue.Queue = queue.Queue(maxsize=100)
    stream = p.open(
        format=fmt,
        channels=channels,
        rate=rate,
        frames_per_buffer=CHUNK,
        input=True,
        input_device_index=dev["index"],
        stream_callback=lambda d, n, t, s: (q.put(d) or (None, pyaudio.paContinue)),
    )

    try:
        while True:
            data = q.get()
            if data is None:
                break
            broadcast(data)
    except KeyboardInterrupt:
        pass
    finally:
        stream.stop_stream()
        stream.close()
        p.terminate()
        srv.close()


if __name__ == "__main__":
    sys.exit(main())
