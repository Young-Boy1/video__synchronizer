# Video Synchronizer

双人同步观影工具——类似 [Syncplay](https://syncplay.pl/)，但**不依赖任何中心服务器**：
两台电脑通过 IPv6/IPv4 **点对点直连**（同一连接上只传控制指令，视频画面与声音走各自本地的
[mpv](https://mpv.io) 播放器），播放、暂停、拖进度在双方之间保持同步。


## 功能

- **P2P 直连**：建房 → 对方粘贴连接码加入（支持全球单播 IPv6 / 局域网 IPv4，连接码点击即复制）
- **同步播放**：任意一方（建房方或加入方）的播放 / 暂停 / 拖进度都会同步到双方
- **稳态同步精度约 0.03 秒**：小偏差由加入方微调播放速度无感追平（音调不变），大偏差直接跳转
- **mpv 窗口双向可控**：直接在 mpv 窗口里按暂停 / 拖进度条，操作同样同步给对方
- **操作提示字幕**：任何一方操作时，双方 mpv 画面左上角弹出提示
  （如「对方暂停了视频」「对方快进了 2 分钟」，停留 3 秒）
- **播完自动处理**：视频播到结尾自动暂停；在结尾处按播放，双方从头重播

## 使用方法

1. 双方各自下载 Release 里的压缩包并解压（`VideoSynchronizer.exe` + `mpv\mpv.exe`；
   如果本机已安装 mpv，只下 exe 也行，程序会自动找到）；
2. 一方点「建房」，窗口会自动复制连接码（形如 `[2402:9002:...]:5577`），发给对方；
3. 对方粘贴连接码点「加入」；两边各自点「打开本地视频」，选择**同一个视频文件**（文件名相同，
   程序自动核对）；
4. 播放 / 暂停 / 拖进度，双向同步，一起看。

> 双方必须都能直连：优先 IPv6（`test-ipv6.com` 可检测），同一局域网可用 IPv4。
> 首次弹「Windows 安全中心警报」时勾选专用网络与公用网络并允许。

## 工作原理

```
┌─ 电脑 A ─────────────┐         TCP 直连          ┌─ 电脑 B ─────────────┐
│ VS 界面(同步逻辑)      │ ←─ 控制指令/快照(≤KB/s) ─→ │ VS 界面(同步逻辑)      │
│  └─ agent(本机驱动)    │      视频数据不经网络      │  └─ agent(本机驱动)    │
│      └─ mpv(命名管道)  │                           │      └─ mpv(命名管道)  │
└──────────────────────┘                           └──────────────────────┘
```

- Godot 负责界面与双机同步（**主机权威**：建房方每 0.3 秒广播带外推时间戳的位置快照，
  加入方对比后以速度微调 / 跳转校正）；
- 本机播放控制外包给无界面驱动器 `agent`（Python 打包），通过命名管道 JSON IPC 控制 mpv——
  与 Syncplay 控制 mpv 的方式相同；
- 正确性关键：mpv 状态查询有延迟，所有同步决策只用"晚于最近一条控制指令"的**新鲜测量状态**，
  避免新旧状态来回横跳。

## 从源码构建

1. 安装 [Godot 4.7.2](https://godotengine.org/download)（标准版即可，导出需同版本导出模板）；
2. 获取 mpv：`python fetch_mpv.py`（国内加 `--mirror`），或从
   [mpv-winbuild-cmake Releases](https://github.com/shinchiro/mpv-winbuild-cmake/releases)
   手动下载 `mpv-x86_64-*.zip`，取其中的 `mpv.exe` 放到 `vendor/mpv/`；
3. 打包 agent 驱动器（需要 Python 3.10+ 与 PyInstaller）：
   ```
   pip install pyinstaller
   cd vendor/agent
   pyinstaller --noconsole --onedir --name VideoSync --distpath build_dist --workpath build_work agent.py
   python -c "import zipfile,os;src=r'build_dist\VideoSync';z=zipfile.ZipFile('agent.zip','w',zipfile.ZIP_DEFLATED,9);z.writestr('ver.txt','6\n');[z.write(os.path.join(r,f),os.path.relpath(os.path.join(r,f),src).replace('\\\\','/')) for r,_,fs in os.walk(src) for f in fs]"
   ```
4. 导出单文件 exe：
   ```
   godot --headless --path . --export-release "Windows Desktop" "../VideoSynchronizer.exe"
   ```

## 运行测试

```
godot --headless --path . --script res://tests/test_sync.gd
```

需要本机可执行 `python`（驱动器以脚本模式启动）；mpv 以 `--vo=null --ao=null` 无窗口运行。

## 目录结构

```
├── project.godot            Godot 4.7 工程
├── src/
│   ├── main.gd/.tscn        大厅：建房 / 加入 / 连接码复制
│   ├── video_sync.gd/.tscn  同步界面：文件核对、同步状态机、操作提示
│   ├── net_link.gd          P2P 联机层（TCP 线协议，主机权威）
│   └── ../tests/test_sync.gd  无头双实例自动化测试
├── vendor/
│   └── agent/               本机 mpv 驱动器（Python 源码 + 打包好的 agent.zip）
├── fetch_mpv.py             mpv 下载脚本（构建者用）
└── export_presets.cfg       Windows 导出配置（不内嵌 mpv，轻量）
```

## 体积说明

导出的 exe 约 100MB（Godot 引擎运行时）。mpv 播放器（约 120MB）不内嵌：
优先使用本机已安装的 mpv，否则把 `mpv.exe` 放到 exe 旁的 `mpv\` 文件夹即可
（Releases 分发的压缩包已包含）。发布 Release 时把导出的 exe 与 mpv 一起打包成 zip。
```

## 许可证

本项目以 [GPL-3.0](LICENSE) 协议开源。

打包分发的 `mpv.exe` 来自 [mpv.io](https://mpv.io)（未修改的上游构建），
mpv 以 **GPLv2+** 授权，其源码见 https://github.com/mpv-player/mpv 。
