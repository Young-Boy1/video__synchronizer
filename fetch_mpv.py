#!/usr/bin/env python3
"""下载 mpv.exe 到 vendor/mpv/（构建导出前运行一次）。

Video Synchronizer 需要 mpv 播放器。为了控制仓库体积，mpv.exe 不入库：
- 普通用户：直接从 GitHub Releases 下载已打包的 VideoSynchronizer.exe（mpv 已内嵌）；
- 开发者构建：先运行本脚本获取 mpv.exe，再用 Godot 导出。

用法:
  python fetch_mpv.py            # 直连 GitHub
  python fetch_mpv.py --mirror   # 走 ghfast.top 加速镜像（国内推荐）
"""
import argparse
import io
import os
import pathlib
import shutil
import sys
import subprocess
import tempfile
import urllib.request
import zipfile

# shinchiro 的 mpv-winbuild-cmake 最新版（Windows x86_64）
API = "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest"
MIRROR = "https://ghfast.top/"
DEST = "vendor/mpv/mpv.exe"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "video-synchronizer"})
    return urllib.request.urlopen(req, timeout=60).read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirror", action="store_true", help="使用 ghfast.top 加速镜像")
    args = ap.parse_args()
    pre = MIRROR if args.mirror else ""

    print("查询最新 mpv 版本…")
    import json
    rel = json.loads(fetch(API))
    asset = None
    for a in rel.get("assets", []):
        name = a["name"]
        if (name.startswith("mpv-x86_64-") and name.endswith((".7z", ".zip"))
                and "v3" not in name):
            asset = a
            break
    if asset is None:
        print("未找到 mpv-x86_64 资产，请到 https://github.com/shinchiro/mpv-winbuild-cmake/releases 手动下载")
        sys.exit(1)
    url = pre + asset["browser_download_url"]
    print("下载:", url)
    data = fetch(url)
    print("大小: %.1f MB" % (len(data) / 1048576))

    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    if asset["name"].endswith(".zip"):
        zf = zipfile.ZipFile(io.BytesIO(data))
        exe = next(n for n in zf.namelist() if n.endswith("mpv.exe"))
        with open(DEST, "wb") as f:
            f.write(zf.read(exe))
    else:
        seven_zip = shutil.which("7z")
        if seven_zip is None:
            print("解压 .7z 资产需要 PATH 中存在 7z", file=sys.stderr)
            sys.exit(1)
        with tempfile.TemporaryDirectory() as temp_dir:
            archive = pathlib.Path(temp_dir) / asset["name"]
            archive.write_bytes(data)
            subprocess.run(
                [seven_zip, "x", str(archive), f"-o{temp_dir}", "-y"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            exe_path = next(pathlib.Path(temp_dir).rglob("mpv.exe"), None)
            if exe_path is None:
                print("mpv 资产中未找到 mpv.exe", file=sys.stderr)
                sys.exit(1)
            shutil.copyfile(exe_path, DEST)
    print("已保存:", DEST)


if __name__ == "__main__":
    main()
