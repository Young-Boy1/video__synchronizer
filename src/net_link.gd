extends Node
## Game Park 联机层：建房/加入 + 行协议消息总线。所有小游戏共用这一条连接。
## 行协议（每行一条消息，以 \n 结尾）：
##   G:<game_id>   切换游戏；game_id 为空表示返回大厅
##   D:<payload>   发给当前小游戏的数据（原样转交 on_data）
## 连接建立后一直保持，换游戏/返回大厅不重连。

signal connected(peer_desc: String)
signal failed(reason: String)
signal disconnected
signal game_switch(game_id: String)
signal game_data(data: String)

const PORT := 5577

var is_host := false  # 本机是否为建房方（游戏用来决定先后手）

var _servers: Array = []
var _peer: StreamPeerTCP
var _alive := false
var _buffer := ""


func host(port: int = PORT) -> Error:
	stop()
	var s6 := TCPServer.new()
	var e6: Error = s6.listen(port, "::")
	var s4 := TCPServer.new()
	var e4: Error = s4.listen(port, "0.0.0.0")
	_servers.clear()
	if e6 == OK:
		_servers.append(s6)
	if e4 == OK:
		_servers.append(s4)
	if _servers.is_empty():
		return e6 if e6 != OK else e4
	is_host = true
	return OK


func join(target: String, port: int = PORT) -> Error:
	stop()
	var parsed := parse_target(target)
	if parsed.is_empty():
		return ERR_INVALID_DATA
	if parsed[1] == PORT:
		parsed[1] = port
	_peer = StreamPeerTCP.new()
	var err: Error = _peer.connect_to_host(parsed[0], parsed[1])
	if err != OK:
		_peer = null
		return err
	is_host = false
	return err


func is_up() -> bool:
	return _alive


func send_game_switch(game_id: String) -> void:
	_send_raw("G:" + game_id)


func send_game_data(data: String) -> void:
	_send_raw("D:" + data)


func stop() -> void:
	for s in _servers:
		s.stop()
	_servers.clear()
	if _peer:
		_peer.close()
	_peer = null
	_alive = false
	_buffer = ""


func _send_raw(line: String) -> void:
	if _alive and _peer:
		_peer.put_data((line + "\n").to_utf8_buffer())


func _process(_delta: float) -> void:
	for s in _servers:
		if s.is_connection_available():
			_peer = s.take_connection()
			for other in _servers:
				if other != s:
					other.stop()
			_servers.clear()
			_alive = true
			connected.emit("%s:%d" % [_peer.get_connected_host(), _peer.get_connected_port()])
			return
	if _peer and not _alive:
		_peer.poll()
		var st := _peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			_alive = true
			connected.emit("%s:%d" % [_peer.get_connected_host(), _peer.get_connected_port()])
		elif st == StreamPeerTCP.STATUS_ERROR:
			failed.emit("对方没有响应（检查连接码、对方是否已建房）")
	if _alive and _peer:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			stop()
			disconnected.emit()
			return
		var n := _peer.get_available_bytes()
		if n > 0:
			var res := _peer.get_data(n)
			if res[0] == OK:
				_buffer += res[1].get_string_from_utf8()
				_drain_lines()


func _drain_lines() -> void:
	while true:
		var idx := _buffer.find("\n")
		if idx < 0:
			break
		var line := _buffer.substr(0, idx).strip_edges()
		_buffer = _buffer.substr(idx + 1)
		if line.begins_with("G:"):
			game_switch.emit(line.substr(2))
		elif line.begins_with("D:"):
			game_data.emit(line.substr(2))


## 解析连接码，支持 "[IPv6]:端口"、"IPv6"、"IPv4:端口"、"主机名:端口"。
## 返回 [host, port]，无法解析返回 []。
static func parse_target(text: String) -> Array:
	var t := text.strip_edges()
	if t.is_empty():
		return []
	var host := ""
	var port := PORT
	if t.begins_with("["):
		var close := t.find("]")
		if close < 0:
			return []
		host = t.substr(1, close - 1)
		var rest := t.substr(close + 1)
		if rest.begins_with(":"):
			port = int(rest.substr(1))
	elif t.contains(":"):
		var colons := t.count(":")
		if colons == 1:
			var parts := t.split(":")
			host = parts[0]
			if parts[1] != "":
				port = int(parts[1])
	else:
		host = t
	if port <= 0 or port > 65535:
		port = PORT
	if host.is_empty():
		return []
	return [host, port]
