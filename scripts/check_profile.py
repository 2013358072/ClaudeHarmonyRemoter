# -*- coding: utf-8 -*-
"""
校验调试签名 Profile 里登记的设备，是否覆盖当前连接的真机。

装不上真机报 9568423（device is unauthorized）时用这个定位：
它会把 Profile 内登记的 UDID 和 hdc 看到的设备逐一比对，
直接告诉你缺哪台，而不是让你去猜。

用法：python scripts/check_profile.py
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEVECO_HDC = r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"


def find_profile_path():
    """从 build-profile.json5 里读出 Profile 路径"""
    p = os.path.join(ROOT, "build-profile.json5")
    if not os.path.exists(p):
        return None
    text = open(p, encoding="utf-8").read()
    m = re.search(r'"profile"\s*:\s*"([^"]+)"', text)
    if not m:
        return None
    # json5 里是转义过的 Windows 路径
    return m.group(1).replace("\\\\", "\\")


def parse_profile(path):
    """
    p7b 是 PKCS#7 二进制，业务信息是内嵌的一段 JSON。
    从每个 '{' 起做花括号配平，取第一个能解出来的对象。
    """
    data = open(path, "rb").read()
    starts = [i for i, b in enumerate(data) if b == 0x7B]
    for s in starts[:400]:
        depth = 0
        for e in range(s, min(len(data), s + 200000)):
            if data[e] == 0x7B:
                depth += 1
            elif data[e] == 0x7D:
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(data[s:e + 1].decode("utf-8"))
                    except Exception:
                        pass
                    break
    return None


def hdc(*args):
    exe = DEVECO_HDC if os.path.exists(DEVECO_HDC) else "hdc"
    try:
        out = subprocess.run(
            [exe, *args], capture_output=True, text=True, timeout=20
        )
        return out.stdout.strip()
    except Exception as e:
        return f"__ERR__ {e}"


def connected_devices():
    """返回 [(连接键, UDID)]"""
    raw = hdc("list", "targets")
    if raw.startswith("__ERR__"):
        print(f"  无法调用 hdc：{raw}")
        return []
    keys = [k for k in raw.splitlines() if k.strip() and "Empty" not in k]
    out = []
    for k in keys:
        k = k.strip()
        r = hdc("-t", k, "shell", "bm", "get", "--udid")
        udid = ""
        for line in r.splitlines():
            line = line.strip()
            # 形如 "udid of current device is :" 后跟一行十六进制
            if re.fullmatch(r"[0-9A-Fa-f]{32,}", line):
                udid = line.upper()
                break
        out.append((k, udid))
    return out


def describe(udid):
    """模拟器的 UDID 以 ASCII 'EMU' 开头，尾部大量补零"""
    if udid.upper().startswith("454D55"):
        return "模拟器"
    return "真机"


def main():
    path = find_profile_path()
    if not path:
        print("[!!] build-profile.json5 里没有签名配置")
        print("  请在 DevEco 里勾选 Automatically generate signature")
        return 1
    if not os.path.exists(path):
        print(f"[!!] Profile 文件不存在：{path}")
        return 1

    print(f"Profile: {path}\n")
    j = parse_profile(path)
    if j is None:
        print("[!!] 无法解析 Profile 内嵌的 JSON")
        return 1

    ptype = j.get("type")
    print(f"类型          : {ptype}")
    print(f"包名          : {j.get('bundle-info', {}).get('bundle-name')}")

    registered = [x.upper() for x in j.get("debug-info", {}).get("device-ids", [])]
    print(f"登记设备数    : {len(registered)}")
    for x in registered:
        print(f"    {x}  [{describe(x)}]")

    print("\n当前连接的设备：")
    devices = connected_devices()
    if not devices:
        print("    （无）")
        return 1

    missing = []
    for key, udid in devices:
        if not udid:
            print(f"    {key:<24} UDID 读取失败（设备可能未授权调试）")
            continue
        ok = udid in registered
        mark = "[OK] 已登记" if ok else "[!!] 未登记"
        print(f"    {key:<24} {describe(udid):<4} {mark}")
        print(f"        {udid}")
        if not ok:
            missing.append((key, udid))

    print()
    if missing:
        print("[!!] 以下设备不在 Profile 里，装上去会报 9568423：")
        for key, _ in missing:
            print(f"    {key}")
        print("\n  修复：DevEco → File → Project Structure → Project → Signing Configs")
        print("       取消勾选 Automatically generate signature，确定后再重新勾选。")
        print("       必须走这一遍取消再勾选 —— 只点一次它会复用已有 Profile 不重新申请。")
        print("       重签时要让目标设备处于连接状态。")
        return 1

    print("[OK] 所有已连接设备都在 Profile 中，可以安装")
    return 0


if __name__ == "__main__":
    sys.exit(main())
