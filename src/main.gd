extends Control
## Video Synchronizer —— 双人同步观影（无服务器，IPv6/IPv4 直连）
## 建房/加入 → 连接成功后直接进入视频同步界面。
## 同步逻辑见 video_sync.gd；联机层见 net_link.gd。

const NetLinkScript := preload("res://src/net_link.gd")
const SyncScene := preload("res://src/video_sync.tscn")
const COL_BLUE := Color("1a73e8")
const COL_GREEN := Color("188038")
const COL_GRAY := Color("666666")

var net: Node
var lobby: VBoxContainer
var status_label: Label
var host_btn: Button
var join_btn: Button
var addr_entry: LineEdit
var code_box: VBoxContainer
var sync_ui: Node


func _ready() -> void:
	# 调试辅助：DUALTEST_POS=x,y 指定窗口位置，便于同机开两个实例对比
	var pos := OS.get_environment("DUALTEST_POS")
	if pos != "":
		var p := pos.split(",")
		if p.size() == 2:
			get_window().position = Vector2i(int(p[0]), int(p[1]))
	get_window().title = "Video Synchronizer"
	_build_ui()
	net = NetLinkScript.new()
	net.name = "NetLink"
	add_child(net)
	net.connected.connect(_on_net_connected)
	net.failed.connect(_on_net_failed)
	net.disconnected.connect(_on_net_disconnected)


# ---------------- UI 构建 ----------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 24)
	add_child(margin)

	lobby = VBoxContainer.new()
	lobby.add_theme_constant_override("separation", 12)
	margin.add_child(lobby)

	var title := _mk_label("Video Synchronizer 双人同步观影", 24)
	title.add_theme_color_override("font_color", COL_BLUE)
	lobby.add_child(title)

	var step := _mk_label("两台电脑直连（不经过服务器），一起看同一部视频。\n第 1 步：其中一台点「建房」；\n第 2 步：另一台粘贴连接码，点「加入」。\n双方各自打开同一个视频文件（文件名相同）即可同步观看。", 14)
	step.add_theme_color_override("font_color", COL_GRAY)
	lobby.add_child(step)

	status_label = _mk_label("等待操作…", 14)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lobby.add_child(status_label)

	host_btn = _mk_button("建房（等待对方加入）", 19)
	host_btn.pressed.connect(_on_host_pressed)
	lobby.add_child(host_btn)

	lobby.add_child(HSeparator.new())

	addr_entry = LineEdit.new()
	addr_entry.placeholder_text = "粘贴对方的连接码，如 [240e:xx::xx]:5577 或 192.168.1.5:5577"
	addr_entry.custom_minimum_size = Vector2(0, 40)
	addr_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addr_entry.text_submitted.connect(func(_t): _on_join_pressed())
	var addr_row := HBoxContainer.new()
	addr_row.add_theme_constant_override("separation", 8)
	addr_row.add_child(addr_entry)
	var paste_btn := Button.new()
	paste_btn.text = "粘贴"
	paste_btn.custom_minimum_size = Vector2(76, 40)
	paste_btn.pressed.connect(func(): addr_entry.text = DisplayServer.clipboard_get())
	addr_row.add_child(paste_btn)
	lobby.add_child(addr_row)

	join_btn = _mk_button("加入", 19)
	join_btn.pressed.connect(_on_join_pressed)
	lobby.add_child(join_btn)

	lobby.add_child(_mk_label("本机连接码（建房后点击即可复制发给对方）：", 13))
	code_box = VBoxContainer.new()
	code_box.add_theme_constant_override("separation", 4)
	lobby.add_child(code_box)
	_refresh_code_buttons()


func _mk_label(text: String, size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	return l


func _mk_button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_size_override("font_size", size)
	return b


## 收集本机可用的连接码：全球单播 IPv6（2xxx:/3xxx:）在前，本机回环在最后
func _candidate_codes() -> Array:
	var codes: Array = []
	for a in IP.get_local_addresses():
		if a.contains(":") and (a.begins_with("2") or a.begins_with("3")):
			codes.append("[%s]:%d" % [a, NetLinkScript.PORT])
	codes.append("[::1]:%d" % NetLinkScript.PORT)
	return codes


## 把每条连接码做成可点击按钮，点击即复制到系统剪贴板
func _refresh_code_buttons() -> void:
	for c in code_box.get_children():
		c.queue_free()
	var codes := _candidate_codes()
	if codes.size() <= 1:
		var l := _mk_label("（未检测到公网 IPv6 —— 同局域网可改发 IPv4；跨网建议用手机热点）", 13)
		l.add_theme_color_override("font_color", COL_GRAY)
		code_box.add_child(l)
		return
	for code in codes:
		var b := Button.new()
		b.text = code
		b.add_theme_font_size_override("font_size", 13)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		b.set_meta("code", code)
		b.pressed.connect(_on_code_pressed.bind(code))
		code_box.add_child(b)


func _on_code_pressed(code: String) -> void:
	DisplayServer.clipboard_set(code)
	for c in code_box.get_children():
		if c is Button:
			c.text = c.get_meta("code")
			c.remove_theme_color_override("font_color")
	for c in code_box.get_children():
		if c is Button and c.get_meta("code") == code:
			c.text = code + "  ✓已复制"
			c.add_theme_color_override("font_color", COL_GREEN)
	if lobby.visible:
		status_label.text = "已复制连接码！直接去微信粘贴发给对方。"


## 自动复制第一条公网 IPv6 连接码（建房时调用，省去手动点击）
func _auto_copy_first_code() -> void:
	for code in _candidate_codes():
		if code.begins_with("[::1]"):
			return  # 只有回环可用时不自动复制
		DisplayServer.clipboard_set(code)


# ---------------- 大厅动作 ----------------

func _on_host_pressed() -> void:
	var err: Error = net.host()
	if err != OK:
		status_label.text = "建房失败：端口 %d 可能被占用（%s）" % [NetLinkScript.PORT, error_string(err)]
		return
	_set_buttons(false)
	_auto_copy_first_code()
	status_label.text = "正在等待对方加入…（连接码已自动复制，去微信粘贴发给对方即可）"


func _on_join_pressed() -> void:
	var target := addr_entry.text
	if target.strip_edges().is_empty():
		status_label.text = "请先粘贴对方的连接码"
		return
	_set_buttons(false)
	status_label.text = "正在连接 %s …" % target.strip_edges()
	var err: Error = net.join(target)
	if err != OK:
		_on_net_failed("连接码格式无法解析")
		return
	_join_timeout(10.0)


func _join_timeout(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	if lobby.visible and not net.is_up():
		_on_net_failed("连接超时：检查连接码是否正确、对方是否已点建房、双方防火墙是否放行")


func _set_buttons(enabled: bool) -> void:
	host_btn.disabled = not enabled
	join_btn.disabled = not enabled


# ---------------- 联机层回调 ----------------

func _on_net_connected(peer_desc: String) -> void:
	# 连接成功 → 直接进入视频同步界面
	lobby.visible = false
	sync_ui = SyncScene.instantiate()
	add_child(sync_ui)
	sync_ui.on_enter(net)


func _on_net_failed(reason: String) -> void:
	net.stop()
	_go_lobby("连接失败：%s" % reason)


func _on_net_disconnected() -> void:
	net.stop()
	_go_lobby("连接已断开，可以重新建房或加入")


func _go_lobby(msg: String) -> void:
	if sync_ui != null:
		sync_ui.on_exit()
		sync_ui.queue_free()
		sync_ui = null
	game_board_cleanup()
	lobby.visible = true
	status_label.text = msg
	_set_buttons(true)


## 兼容 video_sync 旧接口名（其内部通过 net 直接通信，无面板依赖）
func game_board_cleanup() -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		net.stop()
		get_tree().quit()
