#!/usr/bin/env python3
"""Totem 实时层监听:扫描 Peahen Calling BLE 广播,把当前层写入
~/.local/share/totem-keymap/active-layer(供 caelestia dashboard Keymap tab 读取)。

固件侧(左半,ZMK + Peahen Calling 模块)以不可连接广播外发厂商自定义数据:
主机被动扫描即可,无需配对,不干扰分体 BLE 链路。

广播 payload(22 字节厂商数据,BlueZ 把前两字节 company id 拆成 dict key):
  offset 2-3  "A!"              协议签名(company id = 0x4550 "PE")
  offset 4    battery_main      左半电量 0-100
  offset 5    battery_periph    右半电量(0 = 未知)
  offset 6    bt_profile_layer  layer = v // 15,profile = v % 15
  offset 7    status_flags      bit0 usb, bit1 charging, bit2 ble, bit3 caps, bit5 output_usb
  offset 8-17 layer_name        ASCII,null 填充,最长 10 字符
  offset 18   modifiers         HID 修饰键位图
  offset 19   wpm               0-255
  offset 20-21 key_row/key_col  最后按键矩阵位置(未按过 = 0xFF)
"""

import asyncio
import json
import os
import time

# bleak 由 nix profile 的 python 环境提供(见下方 systemd 单元说明)
from bleak import BleakScanner  # type: ignore[import-not-found]

DATA_DIR = os.path.expanduser("~/.local/share/totem-keymap")
ACTIVE_LAYER = os.path.join(DATA_DIR, "active-layer")
STATUS = os.path.join(DATA_DIR, "status.json")

COMPANY_ID = 0x4550  # "PE" — BlueZ 将厂商数据前两字节解析为 company id
PROTO = b"A!"  # 余下 payload 的前两字节签名


def atomic_write(path: str, text: str) -> None:
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError as e:  # 守护进程不该因一次写盘失败而崩,下帧广播会重试
        print(f"[totem] write {path} failed: {e}", flush=True)


def decode(data: bytes):
    """data = 去掉 company id 后的 payload。"""
    # 实发 19 字节(文档说 20,key_row/key_col 被截掉了一字节)——前 18 字节够用
    if len(data) < 18 or data[:2] != PROTO:
        return None
    bpl = data[4]
    flags = data[5]
    return {
        "layer": bpl // 15,
        "bt_profile": bpl % 15,
        "layer_name": data[6:16].split(b"\0")[0].decode("ascii", "replace"),
        "battery_main": data[2],
        "battery_periph": data[3],
        "usb": bool(flags & 0x01),
        "charging": bool(flags & 0x02),
        "ble_connected": bool(flags & 0x04),
        "caps_lock": bool(flags & 0x08),
        "output_usb": bool(flags & 0x20),
        "modifiers": data[16],
        "wpm": data[17],
        "ts": round(time.time()),
    }


class Listener:
    def __init__(self) -> None:
        self.layer = None

    def on_detect(self, _device, adv) -> None:
        payload = adv.manufacturer_data.get(COMPANY_ID)
        if not payload:
            return
        info = decode(payload)
        if info is None:
            return
        if info["layer"] != self.layer:
            self.layer = info["layer"]
            atomic_write(ACTIVE_LAYER, str(info["layer"]))
            print(
                f"[totem] layer -> {info['layer']} ({info['layer_name']})", flush=True
            )
        atomic_write(STATUS, json.dumps(info))


async def main() -> None:
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except OSError as e:
        print(f"[totem] cannot create {DATA_DIR}: {e}", flush=True)
        raise
    listener = Listener()
    scanner = BleakScanner(detection_callback=listener.on_detect)
    print("[totem] scanning for Peahen Calling broadcasts…", flush=True)
    await scanner.start()
    await asyncio.Event().wait()  # 永久运行;崩溃由 systemd Restart 接管


if __name__ == "__main__":
    asyncio.run(main())
