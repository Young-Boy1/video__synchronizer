extends SceneTree
## Video Synchronizer 无头双实例测试（独立项目版）：agent 拉起、文件核对、播放/暂停/跳转同步、
## mpv 窗口内主动拖动的传播、漂移校正。
## 运行：godot --headless --path . --script res://tests/test_sync.gd
## 依赖环境：本机可执行 python（agent 以脚本模式启动），mpv 以 --vo=null/--ao=null 无窗口运行。

const NetLinkScript := preload("res://src/net_link.gd")

var a: Node
var b: Node
var a_conn := false
var b_conn := false
var game_a: Node
var game_b: Node
var media_path := ""
var checks := 0
var fails := 0


func _initialize() -> void:
	a = NetLinkScript.new()
	root.add_child(a)
	b = NetLinkScript.new()
	root.add_child(b)
	a.connected.connect(func(_p): a_conn = true)
	b.connected.connect(func(_p): b_conn = true)
	print("host: ", error_string(a.host(5578)))
	print("join: ", error_string(b.join("[::1]", 5578)))
	_run()


func _check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("PASS: ", msg)
	else:
		fails += 1
		print("TEST FAIL: ", msg)


## 生成 90 秒静音 8kHz 单声道 WAV 作为测试"视频"（mpv 可播放，位置会前进）
func _make_test_wav() -> String:
	var path := OS.get_user_data_dir().path_join("videosync_test.wav")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	var sr := 8000
	var seconds := 90
	var data_bytes := sr * seconds * 2
	f.store_32(0x46464952)                       # RIFF
	f.store_32(36 + data_bytes)
	f.store_32(0x45564157)                       # WAVE
	f.store_32(0x20746D66)                       # fmt
	f.store_32(16)
	f.store_16(1)                                # PCM
	f.store_16(1)                                # mono
	f.store_32(sr)
	f.store_32(sr * 2)
	f.store_16(2)
	f.store_16(16)
	f.store_32(0x61746164)                       # data
	f.store_32(data_bytes)
	var zeros := PackedByteArray()
	zeros.resize(4096)
	for i in int(data_bytes / 4096.0):
		f.store_buffer(zeros)
	f.close()
	return path


func _run() -> void:
	for i in 50:
		await create_timer(0.2).timeout
		if a_conn and b_conn:
			break
	if not (a_conn and b_conn):
		print("TEST FAIL: 连接未建立")
		quit(1)
		return
	print("PASS: connection established")

	media_path = _make_test_wav()
	if media_path == "":
		print("TEST FAIL: 测试 WAV 生成失败")
		quit(1)
		return

	OS.set_environment("VIDEO_SYNC_TEST", "1")  # agent --headless（mpv 无窗口无声）
	OS.set_environment("VIDEO_SYNC_DEBUG", "1")  # 打开同步 trace
	var packed: PackedScene = load("res://src/video_sync.tscn")
	game_a = packed.instantiate()
	game_b = packed.instantiate()
	root.add_child(game_a)
	root.add_child(game_b)
	game_a.on_enter(a)
	game_b.on_enter(b)
	a.game_data.connect(func(d): game_a.on_data(d))
	b.game_data.connect(func(d): game_b.on_data(d))

	_check(game_a.get_title() == "视频同步器", "get_title 正确")
	_check(game_a.net.is_host and not game_b.net.is_host, "A 为主机、B 为加入方")

	# 1) 双方 agent 启动并握手（各占 5579/5580）
	var a_up := false
	var b_up := false
	for i in 60:
		await create_timer(0.5).timeout
		a_up = game_a.agent_up
		b_up = game_b.agent_up
		if a_up and b_up:
			break
	_check(a_up, "A 的 agent 启动成功")
	_check(b_up, "B 的 agent 启动成功")
	if not (a_up and b_up):
		print("INFO: agent 启动失败，提前结束")
		_cleanup()
		return

	# 2) 打开同一个视频文件 → 自动核对
	game_a._on_file_selected(media_path)
	game_b._on_file_selected(media_path)
	await create_timer(2.0).timeout
	_check(game_a.my_loaded and game_b.my_loaded, "双方均已载入媒体")
	_check(game_a.matched == 1 and game_b.matched == 1, "文件核对一致 (a=%d b=%d)" % [game_a.matched, game_b.matched])
	_check(game_a.play_btn.disabled == false, "A 控制按钮已解锁")

	# 等双方 mpv 真正完成启动（首次收到状态回报），避免冷启动时序抖动
	var both_ready := false
	for i in 40:
		await create_timer(0.5).timeout
		if game_a.my_pos_ms > 0 and game_b.my_pos_ms > 0:
			both_ready = true
			break
	_check(both_ready, "双方 mpv 启动完成")

	# 3) 主机点播放 → 快照传播 → 双方播放、位置前进
	game_a._on_play_pressed()
	await create_timer(1.5).timeout
	_check(game_a.my_state == "s" and game_b.my_state == "s", "双方进入播放态 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	var bpos1: float = game_b.my_pos
	await create_timer(1.0).timeout
	_check(game_b.my_pos > bpos1 + 0.3, "加入方位置随播放前进 (%.2f → %.2f)" % [bpos1, game_b.my_pos])

	# 4) 主机拖进度到 30s → 双方跟随
	game_a.slider.value = 30.0
	game_a._on_slider_released(true)
	await create_timer(1.2).timeout
	_check(absf(game_a.my_pos - 30.0) < 1.5, "A 跳转后位置 ≈30 (实际 %.2f)" % game_a.my_pos)
	_check(absf(game_b.my_pos - 30.0) < 3.0, "B 跟随跳转 (实际 %.2f)" % game_b.my_pos)

	# 5) 加入方暂停（走 V:PAUSE 控制链）→ 主机跟随
	game_b._on_play_pressed()
	await create_timer(1.5).timeout
	_check(game_a.my_state == "p" and game_b.my_state == "p", "B 点暂停 → 双方暂停 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])

	# 6) 模拟 B 直接在 mpv 窗口里拖动（agent 直接收 SEEK +15）→ 传给主机
	game_b._send_agent("SEEK 45.0")
	await create_timer(2.0).timeout
	_check(absf(game_b.my_pos - 45.0) < 3.0, "B 本地跳到 45 (实际 %.2f)" % game_b.my_pos)
	_check(absf(game_a.my_pos - 45.0) < 3.5, "A 跟随 B 的本地拖动 (实际 %.2f)" % game_a.my_pos)

	# 7) 播放中小步漂移 → 速度微调自动拉齐（不跳转，无感校正）
	game_a._on_play_pressed()
	await create_timer(1.5).timeout
	_check(game_a.my_state == "s" and game_b.my_state == "s", "恢复播放 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	var drift_target: float = game_b.my_pos + 0.4
	game_b._send_agent("SEEK %.3f" % drift_target)
	await create_timer(8.0).timeout
	# 用外推到当前时刻的位置比较（原始测量各自滞后 0~0.25s，直接比是噪声）
	var now_ms := Time.get_ticks_msec()
	var a_now: float = game_a.my_pos + (minf((now_ms - game_a.my_pos_ms) / 1000.0, 0.5) if game_a.my_state == "s" else 0.0)
	var b_now: float = game_b.my_pos + (minf((now_ms - game_b.my_pos_ms) / 1000.0, 0.5) if game_b.my_state == "s" else 0.0)
	_check(absf(b_now - a_now) < 0.15,
			"速度微调拉齐：0.4s 漂移收敛到 0.15s 内 (a=%.2f b=%.2f 外推差=%.3f)" % [game_a.my_pos, game_b.my_pos, absf(b_now - a_now)])
	_check(absf(game_b.my_speed - 1.0) < 0.005, "拉齐后速度回到 1.0 (%.3f)" % game_b.my_speed)

	# 8) 加入方在播放中拖进度 → 双方必须保持播放态（不许可被暂停），且位置对齐
	game_b.slider.value = 20.0
	game_b._on_slider_released(true)
	await create_timer(1.5).timeout
	_check(game_a.my_state == "s" and game_b.my_state == "s",
			"B 拖进度后双方仍在播放 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	_check(absf(game_a.my_pos - 20.0) < 2.0 and absf(game_b.my_pos - 20.0) < 2.0,
			"B 拖进度生效 (a=%.2f b=%.2f)" % [game_a.my_pos, game_b.my_pos])

	# 9) B 暂停 → A 跟随；B 播放 → A 跟随（来回两轮）
	for round_i in 2:
		game_b._on_play_pressed()
		await create_timer(1.2).timeout
		_check(game_a.my_state == "p" and game_b.my_state == "p",
				"第 %d 轮 B 暂停 → 双方暂停 (a=%s b=%s)" % [round_i + 1, game_a.my_state, game_b.my_state])
		game_b._on_play_pressed()
		await create_timer(1.2).timeout
		_check(game_a.my_state == "s" and game_b.my_state == "s",
				"第 %d 轮 B 播放 → 双方播放 (a=%s b=%s)" % [round_i + 1, game_a.my_state, game_b.my_state])

	# 10) 结尾行为：拖到接近结尾 → keep-open 自动暂停双方 → 按播放从头重播
	game_a.slider.value = game_a.my_dur - 1.0
	game_a._on_slider_released(true)
	await create_timer(3.0).timeout
	_check(game_a.my_state == "p" and game_b.my_state == "p",
			"播到结尾双方自动暂停 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	game_a._on_play_pressed()
	await create_timer(2.0).timeout
	_check(game_a.my_state == "s" and game_b.my_state == "s",
			"结尾按播放 → 双方从头重播 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	_check(game_a.my_pos < 5.0 and game_b.my_pos < 5.0,
			"重播位置从头开始 (a=%.2f b=%.2f)" % [game_a.my_pos, game_b.my_pos])

	# 11) mpv 窗口直接操作（绕过按钮，模拟用户在 mpv 窗口里按键）
	game_b.tcp.put_data("PAUSE
".to_utf8_buffer())
	await create_timer(1.5).timeout
	_check(game_a.my_state == "p" and game_b.my_state == "p",
			"B mpv窗口暂停 → 双方暂停 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	_check(game_b.last_notify == "我暂停了视频" and game_a.last_notify == "对方暂停了视频",
			"mpv 窗口暂停通知路由 (b=%r a=%r)" % [game_b.last_notify, game_a.last_notify])
	game_b.tcp.put_data("PLAY
".to_utf8_buffer())
	await create_timer(1.5).timeout
	_check(game_a.my_state == "s" and game_b.my_state == "s",
			"B mpv窗口播放 → 双方播放 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])
	_check(game_b.last_notify == "我恢复了播放" and game_a.last_notify == "对方恢复了播放",
			"mpv 窗口播放通知路由 (b=%r a=%r)" % [game_b.last_notify, game_a.last_notify])
	await create_timer(1.0).timeout
	_check(game_a.my_state == "s" and game_b.my_state == "s",
			"mpv窗口播放 1 秒后不回暂停 (a=%s b=%s)" % [game_a.my_state, game_b.my_state])

	# 13) main 集成：大厅 → 连接 → 同步界面（覆盖 game_data 转发链）
	var ma: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	var mb: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(ma)
	root.add_child(mb)
	ma._on_host_pressed()
	mb.addr_entry.text = "[::1]:5577"
	mb._on_join_pressed()
	var ui_ready := false
	for i in 60:
		await create_timer(0.5).timeout
		if ma.sync_ui != null and mb.sync_ui != null 				and ma.sync_ui.agent_up and mb.sync_ui.agent_up:
			ui_ready = true
			break
	_check(ui_ready, "main 集成：双方同步界面与 agent 就绪")
	if ui_ready:
		ma.sync_ui._on_file_selected(media_path)
		mb.sync_ui._on_file_selected(media_path)
		var both_loaded := false
		for i in 40:
			await create_timer(0.5).timeout
			if ma.sync_ui.my_pos_ms > 0 and mb.sync_ui.my_pos_ms > 0:
				both_loaded = true
				break
		_check(both_loaded, "main 集成：双方 mpv 启动并载入")
		mb.sync_ui._on_play_pressed()
		await create_timer(1.5).timeout
		_check(ma.sync_ui.my_state == "s" and mb.sync_ui.my_state == "s",
				"main 集成：B 播放同步到 A（game_data 转发正常）(a=%s b=%s)"
						% [ma.sync_ui.my_state, mb.sync_ui.my_state])
	ma._on_net_disconnected()
	mb._on_net_disconnected()

	_cleanup()
	if fails == 0:
		print("TEST PASS: all %d checks ok" % checks)
		quit(0)
	else:
		print("TEST FAIL: %d/%d checks failed" % [fails, checks])
		quit(1)


func _cleanup() -> void:
	for g in [game_a, game_b]:
		if g != null:
			g.on_exit()
