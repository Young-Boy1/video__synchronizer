extends Control
## 视频同步界面：两人各自本地打开同一个视频文件，本模块只同步 播放/暂停/进度。
## 架构：Godot 负责界面 + 双机同步（直连 TCP，主机权威）；
## 本机播放控制外包给无界面驱动器 vendor/agent（localhost TCP 线协议），
## 驱动器再通过命名管道 JSON IPC 控制 mpv（Syncplay 同款接口）。
##
## 同步规则：
##   主机每 0.3s 广播测量快照 V:S:<playing>:<pos>（位置外推到发送时刻）；
##   控制指令应用后立刻广播意图快照；主机状态变化时加入方跟随一次（不盲目镜像）；
##   播放中位置偏差 >0.08s 由加入方微调速度追平（>1.5s 直接跳转）；
##   任一方拖进度/播放/暂停（本程序界面或 mpv 窗口）都会传给主机应用。
##
## 关键正确性设计（新鲜度）：mpv 的状态查询有延迟，命令生效前的查询结果代表
## 过去。每个测量状态都记录其查询发出时间，只有"查询时间 ≥ 最近一次控制指令
## 时间"的状态才用于广播与同步决策（agent 串行应答保证新鲜状态必然包含最新
## 指令的效果），否则新旧状态会来回横跳。

const AGENT_VER := "7"   # 内嵌 agent 版本；与已解包的 agent/ver.txt 不符时自动重解包
const POLL_MY := 0.25    # 本机 mpv 状态轮询周期
const SNAP := 0.3        # 主机快照广播周期
const JUMP := 2.0        # 单个轮询周期内位置突变超过该值 → 视为本方主动拖动
const SNAP_MAX := 0.5    # 位置外推的最大时长（秒），防止异常时钟把外推推飞
const NUDGE_EPS := 0.08  # 漂移超过该值 → 速度微调开始追赶
const NUDGE_DEAD := 0.03 # 漂移小于该值 → 速度回到 1.0
const NUDGE_GAIN := 0.5  # 微调增益：速度 = 1 + 漂移 × 增益
const NUDGE_MAX := 0.12  # 微调幅度上限（1.12 倍速封顶，音调由 mpv 保持不变）
const SEEK_DRIFT := 1.5  # 漂移超过该值 → 直接跳转（微调太慢时才用）

var status_label: Label
var match_label: Label
var open_btn: Button
var play_btn: Button
var slider: HSlider
var time_label: Label
var hint_label: Label
var file_dialog: FileDialog

var net: Node
var tcp: StreamPeerTCP
var agent_pid := 0
var agent_up := false
var token := ""
var mpv_dead := false

var my_loaded := false
var my_file_name := ""
var my_file_size := 0
var peer_file_name := ""
var peer_file_size := 0
var matched := -1  # -1 未核对 / 1 一致 / 0 不一致

var h_playing := false   # 主机权威的播放状态
var h_pos := 0.0
var last_pos := -1.0     # 本机上次轮询位置（突变检测用）
var poll_t := 0.0
var snap_t := 0.0
var dragging := false
var tcp_buf := PackedByteArray()
var my_state := "n"      # n/p/s/d，来自 agent
var my_pos := -1.0
var my_dur := -1.0
var p_sent_ms := 0       # 最近一次 P 查询的发出时刻
var state_fresh := false # 最近一次收到的测量状态是否新于最近一次控制指令
var last_intent_ms := 0  # 最近一次控制指令（本机应用）时刻
var my_pos_ms := 0       # 本机位置测量到达时刻（外推用）
var h_recv_ms := 0       # 对方快照到达时刻（外推用）
var my_speed := 1.0      # 本机已设置的播放速度（加入方微调用）
var mpv_started := false # 本机 mpv 已完成启动（收到过一次状态回报）
var seek_sent_ms := 0    # 最近一次本机 SEEK 发出时刻（滑块位置刷新保护）
var last_notify := ""       # 最近一次本机 mpv 显示的操作提示（测试用）
var last_seek_notify_ms := 0  # 最近一次进度类提示时刻（1 秒内连续拖动合并）
var applying_remote := false   # 正在应用远程状态（期间抑制"本方手动操作"上报）
var applying_until := 0


func get_title() -> String:
	return "视频同步器"


func on_enter(net_: Node) -> void:
	net = net_
	_build_ui()
	_start_agent_async()


func on_data(data: String) -> void:
	if OS.get_environment("VIDEO_SYNC_DEBUG") != "":
		print("[VSYNC %s %5d] <-net %s" % [_tag(), Time.get_ticks_msec() % 100000, data])
	if not data.begins_with("V:"):
		return
	var p := data.substr(2).split(":")
	match p[0]:
		"F":
			peer_file_name = Marshalls.base64_to_utf8(p[1])
			peer_file_size = int(p[2])
			if net.is_host:
				_check_match()
			_refresh_labels()
		"M":
			matched = int(p[1])
			peer_file_name = Marshalls.base64_to_utf8(p[2])
			peer_file_size = int(p[3])
			_refresh_labels()
		"PLAY":
			if net.is_host:
				_host_apply("PLAY")
		"PAUSE":
			if net.is_host:
				_host_apply("PAUSE")
		"SEEK":
			if net.is_host:
				_host_apply("SEEK", p[1])
		"S":
			if not net.is_host:
				var np := p[1] == "1"
				var pos := float(p[2])
				h_recv_ms = Time.get_ticks_msec()
				if np != h_playing:
					_follow_host_state(np, pos)  # 主机状态变化 → 跟随一次
				h_playing = np
				h_pos = pos
		"N":
			last_notify = Marshalls.base64_to_utf8(p[1])
			_send_agent("NOTIFY " + p[1])


func on_exit() -> void:
	set_process(false)
	if tcp != null and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_send_agent("QUIT")  # agent 收到后自己关 mpv 并退出
	elif agent_pid > 0:
		# 还没连接过：惰性启动下 mpv 根本没被拉起，直接杀 agent 无副作用
		OS.kill(agent_pid)
	agent_pid = 0
	if file_dialog != null:
		file_dialog.queue_free()


# ---------------- UI ----------------

func _build_ui() -> void:
	status_label = _mk_label("正在启动本机播放器…", 16)
	add_child(status_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)
	open_btn = Button.new()
	open_btn.text = "打开本地视频…"
	open_btn.custom_minimum_size = Vector2(170, 40)
	open_btn.pressed.connect(_on_open_pressed)
	row.add_child(open_btn)

	match_label = _mk_label("", 13)
	match_label.add_theme_color_override("font_color", Color("666666"))
	match_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(match_label)

	var ctrl := HBoxContainer.new()
	ctrl.add_theme_constant_override("separation", 10)
	add_child(ctrl)
	play_btn = Button.new()
	play_btn.text = "▶ 播放"
	play_btn.custom_minimum_size = Vector2(120, 40)
	play_btn.disabled = true
	play_btn.pressed.connect(_on_play_pressed)
	ctrl.add_child(play_btn)

	slider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0, 32)
	slider.drag_started.connect(func(_v): dragging = true)
	slider.drag_ended.connect(_on_slider_released)
	slider.editable = false
	ctrl.add_child(slider)

	time_label = _mk_label("--:-- / --:--", 14)
	ctrl.add_child(time_label)

	hint_label = _mk_label("双方各自打开同一个视频文件（文件名相同）后即可同步观看；\n播放/暂停/拖进度双方都能控制，在 mpv 窗口里的操作也会自动同步。", 13)
	hint_label.add_theme_color_override("font_color", Color("666666"))
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(hint_label)

	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray([
		"*.mp4, *.mkv, *.avi, *.mov, *.webm, *.m4v, *.ts, *.flv, *.wmv, *.ogv", "*"])
	file_dialog.file_selected.connect(_on_file_selected)
	add_child(file_dialog)


func _mk_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _on_open_pressed() -> void:
	file_dialog.popup_centered(Vector2i(760, 520))


func _on_file_selected(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		status_label.text = "文件打不开：%s" % path
		return
	my_file_size = f.get_length()
	f.close()
	my_file_name = path.get_file()
	status_label.text = "正在载入《%s》…" % my_file_name
	_send_agent("LOAD " + Marshalls.utf8_to_base64(path))
	my_loaded = true
	my_speed = 1.0
	_net_send("V:F:%s:%d" % [Marshalls.utf8_to_base64(my_file_name), my_file_size])
	if net.is_host:
		_check_match()
	_refresh_labels()


## 是否停在文件结尾附近（mpv keep-open 在播完后自动暂停在那里）
func _at_eof() -> bool:
	return my_dur > 0 and my_pos >= 0 and my_pos >= my_dur - 0.3


func _on_play_pressed() -> void:
	var cmd := "PAUSE" if h_playing else "PLAY"
	if cmd == "PLAY" and _at_eof():
		# 播完后再按播放 → 双方从头重播（mpv 在结尾取消暂停只会立即再次到尾暂停）
		_notify("从头重播")
		if net.is_host:
			_host_apply("SEEK", "0.000")
			last_pos = 0.0
		else:
			_send_agent("SEEK 0.000")
			last_pos = 0.0
	if net.is_host:
		if cmd == "PAUSE":
			_notify("暂停了视频")
		elif cmd == "PLAY":
			_notify("恢复了播放")
		_host_apply(cmd)
		return
	if cmd == "PAUSE":
		_notify("暂停了视频")
	elif cmd == "PLAY":
		_notify("恢复了播放")
	_send_agent(cmd)
	# 本方状态迁移已上报，抑制 announce 对同一事件的重复检测
	applying_remote = true
	applying_until = Time.get_ticks_msec() + 1500
	_net_send("V:" + cmd)


func _on_slider_released(changed: bool) -> void:
	dragging = false
	if not changed:
		return
	var t := slider.value
	var from := last_pos if last_pos >= 0 else my_pos
	var d := t - from
	if absf(d) >= 1.0 and Time.get_ticks_msec() - last_seek_notify_ms > 1000:
		last_seek_notify_ms = Time.get_ticks_msec()
		if d > 0:
			_notify("快进了 " + _fmt_delta(d))
		else:
			_notify("后退了 " + _fmt_delta(d))
	if net.is_host:
		_host_apply("SEEK", "%.3f" % t)
		last_pos = t
		return
	_send_agent("SEEK %.3f" % t)
	last_pos = t
	_net_send("V:SEEK:%.3f" % t)


## 主机应用一条控制指令（自己的按钮或对方请求），并立刻广播意图快照
func _host_apply(cmd: String, arg := "") -> void:
	if not net.is_host or mpv_dead:
		return
	last_intent_ms = Time.get_ticks_msec()
	state_fresh = false  # 在途/旧查询结果不再可信
	match cmd:
		"PLAY":
			if _at_eof():
				_send_agent("SEEK 0.000")
				h_pos = 0.0
			_send_agent("PLAY")
			h_playing = true
		"PAUSE":
			_send_agent("PAUSE")
			h_playing = false
		"SEEK":
			_send_agent("SEEK " + arg)
			h_pos = float(arg)
	_net_send("V:S:%d:%.3f" % [1 if h_playing else 0, h_pos])
	_refresh_labels()


func _tag() -> String:
	return "A" if net.is_host else "B"


func _net_send(line: String) -> void:
	if OS.get_environment("VIDEO_SYNC_DEBUG") != "":
		print("[VSYNC %s %5d] net-> %s" % [_tag(), Time.get_ticks_msec() % 100000, line])
	net.send_game_data(line)


## 操作提示：本方 mpv 左上角显示"我…"，对方 mpv 显示"对方…"（各停留 3 秒）
func _notify(action: String) -> void:
	_send_agent("NOTIFY " + Marshalls.utf8_to_base64("我" + action))
	last_notify = "我" + action
	_net_send("V:N:" + Marshalls.utf8_to_base64("对方" + action))


func _fmt_delta(d: float) -> String:
	var s := int(absf(d) + 0.5)
	if s < 60:
		return "%d 秒" % s
	var m := s / 60
	var r := s % 60
	if m >= 60:
		return "%d 小时 %d 分" % [m / 60, m % 60]
	if r > 0:
		return "%d 分 %d 秒" % [m, r]
	return "%d 分钟" % m


# ---------------- agent（本机 mpv 驱动器）----------------

func _agent_command() -> Array:
	# 编辑器/源码运行：直接用 python 跑 agent.py；导出版：用打包好的 VideoSync.exe
	if (OS.has_feature("editor") and OS.get_environment("VIDEO_SYNC_FORCE_EXE") == "") 			or OS.get_environment("VIDEO_SYNC_AGENT_PY") != "":
		var py := OS.get_environment("VIDEO_SYNC_PYTHON")
		if py == "":
			py = "python"
		return [py, ProjectSettings.globalize_path("res://vendor/agent/agent.py")]
	var dir := _extract_dir().path_join("agent")
	var exe := dir.path_join("VideoSync.exe")
	if not FileAccess.file_exists(exe) 			or FileAccess.get_file_as_string(dir.path_join("ver.txt")).strip_edges() != AGENT_VER:
		_extract_agent_zip(dir)  # 首次使用或版本更新 → 重解包
	if FileAccess.file_exists(exe):
		return [exe]
	return [ProjectSettings.globalize_path("res://vendor/agent/VideoSync.exe")]


## 首次使用时把包内自带的 agent.zip（VideoSync 驱动器）解到程序目录
func _extract_agent_zip(dir: String) -> void:
	var zip := ZIPReader.new()
	if zip.open("res://vendor/agent/agent.zip") != OK:
		return
	for f in zip.get_files():
		var rel := f.replace("\\", "/")
		if rel == "" or rel.ends_with("/"):
			continue
		var dst := dir.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var out := FileAccess.open(dst, FileAccess.WRITE)
		if out != null:
			out.store_buffer(zip.read_file(f))
			out.close()
	zip.close()


## mpv 路径解析：环境变量 → 程序目录旁 → 工程内（源码运行）→ PATH → 常见安装位置
func _resolve_mpv() -> String:
	var env := OS.get_environment("MPV_PATH")
	if env != "" and FileAccess.file_exists(env):
		return env
	var candidates := []
	var exe_dir := OS.get_executable_path().get_base_dir()
	candidates.append(exe_dir.path_join("mpv/mpv.exe"))
	candidates.append(exe_dir.path_join("mpv.exe"))
	# 源码运行时：工程内 vendor/mpv（导出版不含 mpv，见 fetch_mpv.py）
	candidates.append(ProjectSettings.globalize_path("res://vendor/mpv/mpv.exe"))
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	# PATH 里找（where 命令；输出形如 C:\x\mpv.exe）
	var where_out: Array = []
	OS.execute("where", ["mpv"], where_out, true)
	for line in String(where_out[0]).split("\n"):
		line = line.strip_edges()
		if line != "" and FileAccess.file_exists(line):
			return line
	for c in ["C:/Program Files/mpv/mpv.exe", "C:/Program Files (x86)/mpv/mpv.exe"]:
		if FileAccess.file_exists(c):
			return c
	return ""


func _extract_dir() -> String:
	# 导出版优先放 exe 旁边（保持在 D 盘、不写 C 盘）；放不下退回 user://
	var dir := OS.get_executable_path().get_base_dir()
	var probe := dir.path_join(".gp_write_test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f != null:
		f.close()
		DirAccess.remove_absolute(probe)
		return dir
	return OS.get_user_data_dir()


func _start_agent_async() -> void:
	var mpv := _resolve_mpv()
	if mpv == "":
		status_label.text = "找不到 mpv 播放器。\n请把 mpv.exe 放到本程序目录旁的 mpv 文件夹内，或安装 mpv 后重开程序，或设置环境变量 MPV_PATH。"
		return
	var cmd := _agent_command()
	var headless := OS.get_environment("VIDEO_SYNC_TEST") != ""  # 哑 mpv（自动化测试用）；DEBUG 只是日志
	for port in range(5579, 5590):
		token = "%08x" % (randi() & 0xFFFFFFFF)
		var args: PackedStringArray = PackedStringArray(cmd)
		args.append_array(PackedStringArray([
			"--mpv", mpv, "--port", str(port), "--token", token]))
		if headless:
			args.append("--headless")
		agent_pid = OS.create_process(cmd[0], args.slice(1))
		if agent_pid <= 0:
			continue
		var ok := await _try_connect(port)
		if ok:
			agent_up = true
			poll_t = 0.0
			set_process(true)
			status_label.text = "正在启动播放器（首次需几秒）…"
			_refresh_labels()
			return
		OS.kill(agent_pid)
		agent_pid = 0
	status_label.text = "本机播放器驱动启动失败（端口 5579-5589 均被占用？）"


func _try_connect(port: int) -> bool:
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		if OS.is_process_running(agent_pid) == false:
			return false
		tcp = StreamPeerTCP.new()
		tcp.connect_to_host("127.0.0.1", port)
		var t2 := Time.get_ticks_msec() + 800
		while Time.get_ticks_msec() < t2:
			tcp.poll()
			if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				break
			if tcp.get_status() == StreamPeerTCP.STATUS_ERROR:
				break
			await get_tree().create_timer(0.05).timeout
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			tcp.disconnect_from_host()
			continue
		# 等 agent 的 HI <token> 握手（防串门：连到别的实例的 agent）
		var t3 := Time.get_ticks_msec() + 1500
		while Time.get_ticks_msec() < t3:
			tcp.poll()
			var n := tcp.get_available_bytes()
			if n > 0:
				var r := tcp.get_data(n)
				if r[0] == OK:
					tcp_buf.append_array(r[1])
				var line := _take_line()
				if line != "":
					if line == "HI " + token:
						return true
					tcp.disconnect_from_host()
					return false
			await get_tree().create_timer(0.05).timeout
		tcp.disconnect_from_host()
	return false


func _take_line() -> String:
	var idx := tcp_buf.find(10)
	if idx < 0:
		return ""
	var line := tcp_buf.slice(0, idx).get_string_from_utf8().strip_edges()
	tcp_buf = tcp_buf.slice(idx + 1)
	return line


func _send_agent(line: String) -> void:
	# 任何会改变本机播放状态的命令都让"测量状态"作废：在途或更早的查询
	# 结果不再代表命令生效后的状态（主机、加入方通用，防新旧状态横跳）
	if line.begins_with("PLAY") or line.begins_with("PAUSE") \
			or line.begins_with("SEEK") or line.begins_with("LOAD"):
		last_intent_ms = Time.get_ticks_msec()
		state_fresh = false
	if line.begins_with("SEEK"):
		seek_sent_ms = Time.get_ticks_msec()
	if tcp != null and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if OS.get_environment("VIDEO_SYNC_DEBUG") != "":
			print("[VSYNC %s %5d] ->agent %s" % [_tag(), Time.get_ticks_msec() % 100000, line])
		tcp.put_data((line + "\n").to_utf8_buffer())
	elif OS.get_environment("VIDEO_SYNC_DEBUG") != "":
		print("[VSYNC %s %5d] !!agent CLOSED, drop %s" % [_tag(), Time.get_ticks_msec() % 100000, line])


# ---------------- 每帧：读 agent 回复 + 轮询 + 快照 ----------------

func _process(delta: float) -> void:
	if not agent_up:
		return
	_drain_tcp()
	if OS.is_process_running(agent_pid) == false:
		agent_up = false
		mpv_dead = true
		status_label.text = "播放器驱动已退出 —— 请返回大厅重新进入"
		_refresh_labels()
		return

	poll_t += delta
	if poll_t >= POLL_MY:
		poll_t = 0.0
		p_sent_ms = Time.get_ticks_msec()
		_send_agent("P")
		_apply_my_poll_state()

	if net.is_host:
		snap_t += delta
		if snap_t >= SNAP:
			snap_t = 0.0
			_host_snapshot_now()


func _drain_tcp() -> void:
	if tcp == null:
		return
	tcp.poll()
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var n := tcp.get_available_bytes()
	if n > 0:
		var r := tcp.get_data(n)
		if r[0] != OK:
			return
		tcp_buf.append_array(r[1])
	while true:
		var line := _take_line()
		if line == "":
			break
		if line.begins_with("S "):
			var p := line.substr(2).split(" ")
			if p.size() >= 3:
				my_state = p[0]
				my_pos = float(p[1])
				my_dur = float(p[2])
				my_pos_ms = Time.get_ticks_msec()
				# 新鲜度：这次查询发出晚于最近一次控制指令，状态才可信
				state_fresh = p_sent_ms >= last_intent_ms
				if OS.get_environment("VIDEO_SYNC_DEBUG") != "":
					print("[VSYNC %s %5d] st=%s pos=%.2f fresh=%s" % [_tag(), Time.get_ticks_msec() % 100000, my_state, my_pos, state_fresh])
		elif OS.get_environment("VIDEO_SYNC_DEBUG") != "":
			print("[VSYNC %s %5d] agent-rep %s" % [_tag(), Time.get_ticks_msec() % 100000, line])


## 本机轮询后的处理：界面刷新 + 本方在 mpv 窗口里的操作检测（只用新鲜状态）
func _apply_my_poll_state() -> void:
	if my_state == "d" and not mpv_dead:
		mpv_dead = true
		status_label.text = "mpv 播放器已退出 —— 请返回大厅重新进入"
		_refresh_labels()
		return
	if my_dur > 0 and slider.max_value < 1.5:
		slider.max_value = my_dur
	if not mpv_started and my_pos_ms > 0:
		mpv_started = true
		status_label.text = "播放器就绪 —— 双方各自打开同一个视频文件（文件名需一致）"
	if _at_eof() and my_state == "p":
		status_label.text = "播放结束 —— 任意一方再按「播放」将从头重播"
	if state_fresh and my_loaded:
		# 先应用远程状态，再检测本方手动操作：否则远程刚要求的状态还没落地时，
		# 会被旧测量误判成"用户手动改了状态"而反向广播，形成乒乓
		_reconcile()
		# 远程状态已确认落地 → 解除上报抑制
		if applying_remote and state_fresh and my_state in ["s", "p"] 				and (my_state == "s") == h_playing:
			applying_remote = false
		if Time.get_ticks_msec() > applying_until:
			applying_remote = false
		# 检测本方直接在 mpv 窗口里拖动进度（位置突变）→ 当作主动操作广播
		if last_pos >= 0 and my_pos >= 0 and my_state != "d":
			if absf(my_pos - last_pos) > JUMP:
				var d := my_pos - last_pos
				if Time.get_ticks_msec() - last_seek_notify_ms > 1000:
					last_seek_notify_ms = Time.get_ticks_msec()
					if d > 0:
						_notify("快进了 " + _fmt_delta(d))
					else:
						_notify("后退了 " + _fmt_delta(d))
				if net.is_host:
					_host_snapshot_now()
				else:
					_net_send("V:SEEK:%.3f" % my_pos)
		# 检测本方在 mpv 窗口里按了暂停/播放 → 广播给主机
		var playing := my_state == "s"
		if playing != h_playing and not applying_remote:
			if playing:
				_notify("恢复了播放")
			else:
				_notify("暂停了视频")
			if net.is_host:
				# 主机是权威：测量状态立即广播，不设抑制窗口
				#（否则主机上 1.5 秒内的连续操作会被吞掉一次，对面延迟跟随）
				h_playing = playing
				_host_snapshot_now()
			else:
				# 加入方：上报在途，防止主机意图落地前重复广播
				applying_remote = true
				applying_until = Time.get_ticks_msec() + 1500
				_net_send("V:%s" % ("PLAY" if playing else "PAUSE"))
	last_pos = my_pos
	_refresh_time_ui()


## 主机状态发生变化 → 加入方跟随一次（带位置吸附）。
## 注意：只跟随"变化"，不盲目镜像——否则本机 mpv 窗口里的用户操作
## 会在一个轮询周期内被改回去，等于加入方的 mpv 窗口单向失效。
func _follow_host_state(playing: bool, pos: float) -> void:
	applying_remote = true
	applying_until = Time.get_ticks_msec() + 2000
	if playing:
		if my_pos >= 0 and absf(pos - my_pos) > 0.2:
			_send_agent("SEEK %.3f" % pos)
		_send_agent("PLAY")
	else:
		_send_agent("PAUSE")
	last_pos = -1.0
	my_speed = 1.0


## 加入方：按主机快照校正自己（每次轮询执行一遍，形成连续的追同环）。
## 两边位置都外推到"现在"再比较：主机快照位置 + 快照到达后的流逝时间，
## 本机位置 + 测量后的流逝时间。否则轮询间隔本身的滞后会被当成漂移。
func _reconcile() -> void:
	if net.is_host or not agent_up or not my_loaded or mpv_dead:
		return
	var now := Time.get_ticks_msec()
	var host_now: float = h_pos
	if h_playing and h_recv_ms > 0:
		host_now += minf((now - h_recv_ms) / 1000.0, SNAP_MAX)
	var mine_now: float = my_pos
	if my_state == "s" and my_pos >= 0:
		mine_now += minf((now - my_pos_ms) / 1000.0, SNAP_MAX)

	# 状态跟随已移至 _follow_host_state（只在主机状态变化时触发一次）；
	# 这里不再镜像播放状态，否则会吞掉本机 mpv 窗口里的用户操作

	# 非播放态：速度复位
	if not (h_playing and my_state == "s"):
		if absf(my_speed - 1.0) > 0.001:
			_send_agent("SPEED 1.000")
			my_speed = 1.0
		return

	# 漂移处理：小漂移速度微调（平滑无感），大漂移直接跳转
	var drift := host_now - mine_now
	if absf(drift) > SEEK_DRIFT:
		_send_agent("SPEED 1.000")
		_send_agent("SEEK %.3f" % host_now)
		my_speed = 1.0
		last_pos = -1.0
	elif absf(drift) > NUDGE_EPS:
		var target := 1.0 + clampf(drift * NUDGE_GAIN, -NUDGE_MAX, NUDGE_MAX)
		if absf(target - my_speed) > 0.005:
			_send_agent("SPEED %.3f" % target)
			my_speed = target
	elif absf(drift) <= NUDGE_DEAD and absf(my_speed - 1.0) > 0.001:
		_send_agent("SPEED 1.000")
		my_speed = 1.0


# ---------------- 主机快照与文件核对 ----------------

func _host_snapshot_now() -> void:
	if not net.is_host or not state_fresh:
		return  # 测量状态还停留在最近一条指令之前，广播出去会和新旧状态打架
	h_playing = my_state == "s"
	h_pos = my_pos if my_pos >= 0 else h_pos
	# 外推：测量是 my_pos_ms 时刻做的，播放中则推算到发送时刻，消除轮询滞后偏差
	var send_pos := h_pos
	if h_playing and my_pos_ms > 0:
		send_pos += minf((Time.get_ticks_msec() - my_pos_ms) / 1000.0, SNAP_MAX)
	_net_send("V:S:%d:%.3f" % [1 if h_playing else 0, send_pos])


func _check_match() -> void:
	if my_file_name == "" or peer_file_name == "":
		return
	var ok := my_file_name.to_lower() == peer_file_name.to_lower() and my_file_size == peer_file_size
	matched = 1 if ok else 0
	_net_send("V:M:%d:%s:%d" % [matched, Marshalls.utf8_to_base64(my_file_name), my_file_size])
	_refresh_labels()


func _refresh_labels() -> void:
	var can := agent_up and my_loaded and matched == 1 and not mpv_dead
	play_btn.disabled = not can
	slider.editable = can
	if mpv_dead:
		match_label.text = ""
		return
	var lines: PackedStringArray = []
	if peer_file_name != "":
		lines.append("对方已打开：《%s》（%s）" % [peer_file_name, _fmt_size(peer_file_size)])
	match matched:
		1:
			lines.append("文件一致 ✓ 可以开始同步观看")
			match_label.add_theme_color_override("font_color", Color("188038"))
		0:
			lines.append("警告：双方文件不一致（名称或大小不同），请确认打开同一部电影")
			match_label.add_theme_color_override("font_color", Color("c5221f"))
		_:
			if my_file_name != "" and peer_file_name == "":
				lines.append("等待对方打开视频…")
			match_label.add_theme_color_override("font_color", Color("666666"))
	match_label.text = "\n".join(lines)
	_refresh_time_ui()


func _refresh_time_ui() -> void:
	time_label.text = "%s / %s" % [_fmt_time(my_pos), _fmt_time(my_dur)]
	if not dragging and my_pos >= 0 and slider.max_value > 0 \
			and Time.get_ticks_msec() - seek_sent_ms > 800:
		slider.set_value_no_signal(clampf(my_pos, 0, slider.max_value))
	play_btn.text = "⏸ 暂停" if h_playing else "▶ 播放"


func _fmt_time(t: float) -> String:
	if t < 0:
		return "--:--"
	var total := int(t)
	var s := total % 60
	var m := (total / 60) % 60
	var h := total / 3600
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%02d:%02d" % [m, s]


func _fmt_size(n: int) -> String:
	if n >= 1 << 30:
		return "%.2f GB" % (float(n) / (1 << 30))
	if n >= 1 << 20:
		return "%.1f MB" % (float(n) / (1 << 20))
	return "%.0f KB" % (float(n) / 1024.0)
