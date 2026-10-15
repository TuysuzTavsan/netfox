extends RefCounted
class_name _ViewDelayTracker

## Helper class for tracking how many ticks behind each client sees the host's
## simulation.
##
## [b]View delay[/b] is the number of ticks between a client's current tick and
## the tick of the host's simulation that the client is seeing. When a client
## fires at tick [code]t[/code], it was seeing the host's simulation at tick
## [code]t - view_delay[/code]. [_SimulatorServer] uses this to find the tick
## to rewind to when registering projectiles.
## [br][br]
## [b]Measuring[/b]: clients measure their view delay every time a simulator
## state arrives from the host, as [code]current tick - state tick[/code], and
## keep that value until the next state arrives. Full states arrive at least
## every [code]netfox/simulator/full_state_interval[/code] ticks, which keeps
## the measurement fresh.
## [br][br]
## [b]Why on arrival[/b]: with diff states, the host sends nothing while
## nothing changes. Computing [code]current tick - newest received tick[/code]
## every tick instead would keep growing in that case, even though the client
## still sees an up to date world. Example, with a real view delay of 10 ticks
## and nothing changing after tick 100:
## [codeblock]
## client tick | arrives            | every tick | on arrival
## 110         | state for tick 100 | 10         | 10
## 120         | nothing            | 20         | 10
## 130         | nothing            | 30         | 10
## 134         | full state for 124 | 10         | 10
## [/codeblock]
## If the client fires at tick 130, it sees the world as it is at tick 120,
## since nothing changed between 100 and 120. With 30, the host would start the
## projectile at tick 100 and step it 20 ticks too many, so it ends up further
## along its path than where the client fired it. With 10, it starts at 120.
## [br][br]
## The downside is lag spikes: if states are stuck on the network instead,
## the client can't tell that apart from "nothing changed", see the TODO below.
## [br][br]
## [b]Sending[/b]: clients send [code](tick, view delay)[/code] samples to the
## host, 6 bytes each, on an unreliable command. To keep traffic low, a sample
## is sent:
## [br]- periodically, every
## [code]netfox/simulator/view_delay_send_interval[/code] seconds, and
## [br]- immediately, if the view delay changed by at least
## [code]netfox/simulator/view_delay_change_threshold[/code] seconds since the
## last sample sent.
## [br]Changes smaller than that are just network jitter, and are picked up by
## the next periodic sample. A lost sample is fine too, the next one replaces it.
## [br]Both settings are in seconds, so they behave the same at any tick rate.
## They're converted to ticks once, in [method initialize].
## [br][br]
## [b]Storing[/b]: the host keeps a per peer history of samples, mapping client
## ticks to view delays. This way every projectile is matched with the view
## delay at the tick it was fired, even if fire events from different ticks
## arrive at the same time, e.g. after a lag spike. History older than
## [code]netfox/simulator/history_limit[/code] ticks is dropped automatically.
## [br][br]
## Used by [_SimulatorServer] internally.

# TODO: Detect lag spikes? During a spike we should use
# current tick - newest received tick as view delay instead?

var _owner: Node = null
var _cmd_view_delay: _NetworkCommandServer.Command = null
var _history_size: int = 64
var _logger := NetfoxLogger._for_netfox("ViewDelayTracker")

# Client side: ticks between periodic samples, set in initialize().
# netfox/simulator/view_delay_send_interval, rounded up to whole ticks.
# by default is = 1.
var _send_interval_ticks : int = 1

# Client side: view delay change that is sent immediately, set in initialize().
# netfox/simulator/view_delay_change_threshold, rounded up to whole ticks.
# by default is = 2.
var _change_threshold_ticks : int = 2

# Client side: latest measured view delay, -1 if nothing measured yet
var _local_view_delay: int = -1

# Client side: newest simulator state tick received from the host
var _latest_received_tick: int = -1

# Client side: last sample sent, -1 if nothing sent yet
var _last_sent_tick: int = -1
var _last_sent_view_delay: int = -1

# Host side: peer id -> _HistoryBuffer of client tick -> view delay
var _view_delay_histories: Dictionary[int, _HistoryBuffer] = {}

## Initialize needs to be called by the owner node, from its _ready().
## Commands must be registered in the same order on every peer, which is
## guaranteed for autoloads.
func initialize(owner: Node, command_server: _NetworkCommandServer, synchronization_server: _NetworkSynchronizationServer, history_size: int) -> void:
	_owner = owner
	_history_size = history_size

	var send_interval := ProjectSettings.get_setting("netfox/simulator/view_delay_send_interval", 0.25) as float
	var change_threshold := ProjectSettings.get_setting("netfox/simulator/view_delay_change_threshold", 0.06) as float

	# At least 1 tick, in case the interval is shorter than a tick
	_send_interval_ticks = maxi(1, ceili(send_interval / NetworkTime.ticktime))

	# At least 2 ticks, so +/- 1 tick of jitter never counts as a change
	_change_threshold_ticks = maxi(2, ceili(change_threshold / NetworkTime.ticktime))

	_cmd_view_delay = command_server.register_command(_handle_view_delay, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)

	synchronization_server._on_simulator.connect(_on_simulator_state)
	NetworkTime.after_tick_loop.connect(_send_view_delay)

	owner.multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	owner.multiplayer.connected_to_server.connect(_reset_client)
	owner.multiplayer.server_disconnected.connect(_reset_client)

## Returns the view delay [param peer] had at [param tick], or [param default]
## if there's no sample for it, e.g. the peer hasn't reported yet, or
## [param tick] is older than the history.
## [br][br]
## [param tick] is in the peer's ticks, e.g. the tick of its fire input.
func get_view_delay(peer: int, tick: int, default: int) -> int:
	var history := _view_delay_histories.get(peer) as _HistoryBuffer
	if history == null:
		return default

	var view_delay: Variant = history.get_latest_at(tick)
	if view_delay == null:
		return default

	return view_delay as int

# Client side, called for every simulator state received from the host.
func _on_simulator_state(snapshot: _Snapshot) -> void:
	# Ignore states arriving out of order, the client already sees a newer one
	if snapshot.tick < _latest_received_tick:
		return

	_latest_received_tick = snapshot.tick
	_local_view_delay = maxi(0, NetworkTime.tick - snapshot.tick)

# Client side, called after every tick loop. Sends a sample if it's time for a
# periodic one, or if the view delay changed enough, see _change_threshold_ticks.
func _send_view_delay() -> void:
	if _local_view_delay < 0:
		# Nothing measured yet
		return

	var multiplayer := _owner.multiplayer
	if not multiplayer.has_multiplayer_peer() or multiplayer.is_server():
		return

	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	# This is the tick whose inputs are gathered next, so a fire input made
	# right after this gets this tick
	var tick := NetworkTime.tick

	var is_periodic := _last_sent_tick < 0 or tick - _last_sent_tick >= _send_interval_ticks
	var has_changed := absi(_local_view_delay - _last_sent_view_delay) >= _change_threshold_ticks
	if not is_periodic and not has_changed:
		return

	var buffer := StreamPeerBuffer.new()
	buffer.put_u32(tick)
	buffer.put_u16(mini(_local_view_delay, 0xFFFF))
	_cmd_view_delay.send(buffer.data_array, MultiplayerPeer.TARGET_PEER_SERVER)

	_last_sent_tick = tick
	_last_sent_view_delay = _local_view_delay

# Host side, stores a sample reported by a client.
func _handle_view_delay(sender: int, data: PackedByteArray) -> void:
	if not _owner.multiplayer.is_server():
		return

	if data.size() != 6:
		_logger.warning("Received malformed view delay from peer #%d, ignoring", [sender])
		return

	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data
	var tick := buffer.get_u32()
	var view_delay := buffer.get_u16()

	# Ticks older than the history size are dropped by the buffer itself
	var history := _view_delay_histories.get(sender) as _HistoryBuffer
	if history == null:
		history = _HistoryBuffer.new(_history_size)
		_view_delay_histories[sender] = history

	history.set_at(tick, view_delay)

func _on_peer_disconnected(peer: int) -> void:
	_view_delay_histories.erase(peer)

# Client side, start measuring from scratch on every new connection.
func _reset_client() -> void:
	_local_view_delay = -1
	_latest_received_tick = -1
	_last_sent_tick = -1
	_last_sent_view_delay = -1
