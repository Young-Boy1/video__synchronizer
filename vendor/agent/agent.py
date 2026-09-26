"""Video Synchronizer —— 本机 mpv 驱动器（无界面）。

被 Video Synchronizer（Godot 界面）拉起，职责只有一件事：在本机控制 mpv。
同步逻辑全部在 Godot 侧；本工具不做任何双机通信。

用法:
  python agent.py --mpv <mpv.exe 路径> --port 5579 --token <串> [--headless]

与 Godot 的线协议（127.0.0.1:port，一行一命令，UTF-8）:
  连接建立后 agent 先发一行: HI <token>
  LOAD <b64路径>   载入媒体并暂停      → OK / ERR <原因>
  PLAY             取消暂停            → OK / ERR
  PAUSE            暂停                → OK / ERR
  SEEK <秒>        绝对跳转            → OK / ERR
  SPEED <倍速>     微调播放速度(同步用) → OK / ERR
  NOTIFY <b64文本>  mpv 左上角 OSD 显示文字 3 秒 → OK / ERR
  P                查询状态            → S <p|s|n|d> <pos> <dur> <speed>
                   p=已暂停 s=播放中 n=未载入/启动中 d=mpv 已退出；未知为 -1
  QUIT             关闭 mpv 并退出     → OK（随后断开）

生命周期（防孤儿窗口设计）:
  mpv 惰性启动 —— 只有客户端真正连上才开始拉起 mpv；连接前 agent 被杀
  不会留下任何 mpv 窗口。启动后 20 秒无人连接（游戏提前退出）→ 静默退出；
  会话结束（QUIT 或连接断开）→ 关 mpv 并退出。
端口被占用时进程以退出码 2 结束，由 Godot 换端口重试。
"""
import argparse
import base64
import json
import os
import random
import socket
import subprocess
import sys
import threading
import time

PIPE_NAME = "gpmpv-%d-%d" % (random.randint(1000, 9999), random.randint(1000, 9999))
PIPE_PATH = "\\\\.\\pipe\\" + PIPE_NAME


class MpvDriver:
    """通过命名管道 JSON IPC 控制本机 mpv（Syncplay 同款接口）。
    mpv 惰性启动：客户端连上后才在后台线程拉起，
    "连接前 agent 被杀"绝不会留下孤儿 mpv 窗口。"""

    def __init__(self, mpv_path: str, headless: bool):
        self.dead = False
        self.pipe = None
        self.lock = threading.Lock()
        self.req_id = 0
        self.mpv_path = mpv_path
        self.headless = headless
        self.proc = None
        self.ready = threading.Event()

    def start_async(self) -> None:
        threading.Thread(target=self._spawn, daemon=True).start()

    def _spawn(self) -> None:
        args = [
            self.mpv_path, "--no-config", "--no-terminal", "--idle=yes",
            "--keep-open=yes", "--pause", "--input-ipc-server=" + PIPE_NAME,
            "--sub-auto=fuzzy", "--hwdec=auto-safe",
            "--title=Video Synchronizer 视频同步",
        ]
        if self.headless:
            args += ["--vo=null", "--ao=null"]
        else:
            args += ["--force-window=yes"]
        try:
            self.proc = subprocess.Popen(args)
        except OSError as e:
            print("ERR mpv spawn: %s" % e)
            self.dead = True
            self.ready.set()
            return
        t0 = time.time()
        while time.time() - t0 < 15.0:
            if self.proc.poll() is not None:
                self.dead = True
                break
            try:
                self.pipe = open(PIPE_PATH, "r+b", buffering=0)
                break
            except OSError:
                time.sleep(0.15)
        else:
            self.dead = True
        self.ready.set()

    def _wait_ready(self, seconds: float = 16.0) -> bool:
        self.ready.wait(seconds)
        return self.ready.is_set() and not self.dead

    def _readline(self) -> bytes:
        buf = bytearray()
        while True:
            b = self.pipe.read(1)
            if not b:
                raise OSError("mpv pipe closed")
            if b == b"\n":
                return bytes(buf)
            if b != b"\r":
                buf += b

    def request(self, cmd: list) -> dict:
        """发送一条 IPC 命令并返回其响应（跳过 mpv 的异步 event 行）。"""
        with self.lock:
            if self.dead:
                return {"error": "dead"}
            if not self._wait_ready():
                return {"error": "dead"}
            try:
                self.req_id += 1
                line = json.dumps({"command": cmd, "request_id": self.req_id},
                                  ensure_ascii=True)
                self.pipe.write((line + "\n").encode("utf-8"))
                self.pipe.flush()
                t0 = time.time()
                while time.time() - t0 < 6.0:
                    d = json.loads(self._readline().decode("utf-8", "replace"))
                    if d.get("request_id") == self.req_id:
                        return d
                    # 其余行是 event，跳过
                return {"error": "timeout"}
            except (OSError, ValueError):
                self.dead = True
                return {"error": "dead"}

    def get_prop(self, name: str):
        r = self.request(["get_property", name])
        return r.get("data") if r.get("error") == "success" else None

    def status(self) -> tuple:
        """返回 (state, pos, dur, speed)：state ∈ p/s/n/d。"""
        if self.proc is not None and self.proc.poll() is not None:
            self.dead = True
        if self.dead:
            return ("d", -1.0, -1.0, 1.0)
        if not self.ready.is_set():
            return ("n", -1.0, -1.0, 1.0)  # mpv 还在启动中
        idle = self.get_prop("idle-active")
        if idle is None:
            return ("d", -1.0, -1.0, 1.0)
        if idle:
            return ("n", -1.0, -1.0, 1.0)
        pause = self.get_prop("pause")
        if pause is None:
            return ("n", -1.0, -1.0, 1.0)
        pos = self.get_prop("time-pos")
        dur = self.get_prop("duration")
        spd = self.get_prop("speed")
        return ("p" if pause else "s",
                -1.0 if pos is None else float(pos),
                -1.0 if dur is None else float(dur),
                1.0 if spd is None else float(spd))

    def load(self, path: str) -> str:
        r = self.request(["loadfile", path, "replace"])
        if r.get("error") != "success":
            return "载入失败: %s" % r.get("error")
        r = self.request(["set_property", "pause", True])
        if r.get("error") != "success":
            return "载入失败: %s" % r.get("error")
        self.request(["set_property", "speed", 1.0])
        return ""

    def play(self) -> str:
        r = self.request(["set_property", "pause", False])
        return "" if r.get("error") == "success" else str(r.get("error"))

    def pause(self) -> str:
        r = self.request(["set_property", "pause", True])
        return "" if r.get("error") == "success" else str(r.get("error"))

    def seek(self, t: float) -> str:
        r = self.request(["seek", repr(t), "absolute", "exact"])
        return "" if r.get("error") == "success" else str(r.get("error"))

    def speed(self, v: float) -> str:
        r = self.request(["set_property", "speed", v])
        return "" if r.get("error") == "success" else str(r.get("error"))

    def show_text(self, text: str) -> str:
        r = self.request(["show-text", text, 3000])
        return "" if r.get("error") == "success" else str(r.get("error"))

    def quit_mpv(self) -> None:
        self.request(["quit"])
        if self.proc is not None:
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def handle_client(conn: socket.socket, drv: MpvDriver, token: str) -> None:
    """处理 Video Synchronizer 客户端连接；断开或 QUIT 后由 main 收尾退出。"""
    conn.sendall(("HI %s\n" % token).encode("ascii"))
    buf = bytearray()
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                reply = dispatch(line, drv)
                conn.sendall((reply + "\n").encode("utf-8"))
                if line == "QUIT":
                    os._exit(0)  # QUIT = 连 mpv 一起退出整个 agent
    except OSError:
        return


def dispatch(line: str, drv: MpvDriver) -> str:
    parts = line.split(" ", 1)
    cmd = parts[0]
    try:
        if cmd == "LOAD":
            path = base64.b64decode(parts[1]).decode("utf-8")
            err = drv.load(path)
            return "OK" if not err else "ERR " + err
        if cmd == "PLAY":
            err = drv.play()
            return "OK" if not err else "ERR " + err
        if cmd == "PAUSE":
            err = drv.pause()
            return "OK" if not err else "ERR " + err
        if cmd == "SEEK":
            err = drv.seek(float(parts[1]))
            return "OK" if not err else "ERR " + err
        if cmd == "SPEED":
            err = drv.speed(float(parts[1]))
            return "OK" if not err else "ERR " + err
        if cmd == "NOTIFY":
            text = base64.b64decode(parts[1]).decode("utf-8")
            err = drv.show_text(text)
            return "OK" if not err else "ERR " + err
        if cmd == "P":
            st, pos, dur, spd = drv.status()
            return "S %s %.3f %.3f %.3f" % (st, pos, dur, spd)
        if cmd == "QUIT":
            drv.quit_mpv()
            return "OK"
        return "ERR unknown"
    except (ValueError, IndexError) as e:
        return "ERR %s" % e


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mpv", required=True)
    ap.add_argument("--port", type=int, default=5579)
    ap.add_argument("--token", default="")
    ap.add_argument("--headless", action="store_true")
    ns = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", ns.port))
    except OSError:
        print("ERR port %d busy" % ns.port)
        sys.exit(2)
    srv.listen(2)
    srv.settimeout(20)  # 20 秒无人连接（游戏提前退出）→ 静默退出，mpv 都没起，无孤儿

    drv = MpvDriver(ns.mpv, ns.headless)
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        sys.exit(0)
    drv.start_async()  # 有人连上了才开始拉 mpv
    handle_client(conn, drv, ns.token)
    # 会话结束（QUIT 或连接断开）→ 关 mpv 并退出，不留孤儿窗口
    drv.quit_mpv()
    sys.exit(0)


if __name__ == "__main__":
    main()
