extends Node
class_name _InputSenderServer

# @public class

## Handles [InputSender] related operations.

## InputSenderServer assumes input snapshots arrive as whole. (atomic), if snapshot
## arrives with multiple parts, [InputSender] signals wont be reliable to 
## code game logic.

static var _logger := NetfoxLogger._for_netfox("InputSenderServer")

var _history_server : NetworkHistoryServer = null
var _synchronization_server : NetworkSynchronizationServer = null

var _missing_inputs_history_size : int = ProjectSettings.get_setting("netfox/input_sender/missing_input_history", 16)
var _input_sender_history_size : int = ProjectSettings.get_setting("netfox/input_sender/history_limit", 64)

# A lead change skips at most this many stamps. A bigger jump means time
# jumped forward, e.g. after a pause, and the skipped stamps aren't filled.
const MAX_FILLED_STAMPS := 4

# Latest tick our own inputs were recorded under, -1 if nothing recorded yet.
# Inputs are stamped with tick + input lead, see _SimulatorTimeTracker.
var _last_recorded_tick : int = -1

# Stamp of our latest gathered input that local_input wasn't emitted for yet,
# -1 if none. Filled stamps are predicted, not gathered, so they're not here.
var _pending_local_input_tick : int = -1

# Inputs held back for a tick because the input lead shrank, see
# _record_and_send_inputs. Maps InputSender -> input Dictionary.
var _held_inputs : Dictionary[InputSender, Dictionary] = {}

# Ticks that we received new input snapshots.
var _ticks_that_has_new_snapshot : Array[int] = []

# Maps InputSender -> InputSenderHistory (inner class, look at the end of this script.)
var _per_input_sender_history : Dictionary = {}

func _ready():
	# Ensure dependencies
	if not _history_server: _history_server = NetworkHistoryServer
	if not _synchronization_server: _synchronization_server = NetworkSynchronizationServer
	
	# Missing inputs are looked up missing_input_history ticks back, so they
	# have to be inside the history_limit ticks of the past that are kept.
	if _missing_inputs_history_size >= _input_sender_history_size:
		_logger.warning(
			"netfox/input_sender/missing_input_history (%d) must be smaller than " +
			"netfox/input_sender/history_limit (%d), using %d",
			[_missing_inputs_history_size, _input_sender_history_size, _input_sender_history_size - 1])
		_missing_inputs_history_size = maxi(0, _input_sender_history_size - 1)
	
	# Record inputs similiar to rollback so that users can use same methods
	# on their input scripts.
	# For good reasons, We do logic and run InputSender signals on NetworkTime.on_tick
	# This means local players wont have input information for their first tick.
	# Its not really like await processframe but this will only add slight delay that wont have
	# Important effects on the game itself.
	NetworkTime.after_tick.connect(_record_and_send_inputs)
	
	# Ticks start over when NetworkTime starts, so do the stamps.
	NetworkTime.after_sync.connect(_reset_stamps)
	
	_synchronization_server._on_input_sender.connect(_on_received_input_snapshot)
	
	# About when we should process our inputs:
	# It doesnt make sense to process them when we receive them, as it will break the
	# work order of [Simulator]s or [TickInterpolator]s, or we might want this to work
	# with physics. It would be unreliable.
	# Therefore we need to process them in a fixed point.
	# Processing them on every tick doesnt make sense, since host may run multiple
	# ticks and we probably wont even have new inputs to process anyway.
	# In conculusion it makes sense to process them after a tick loop run.
	#
	# But if we run logic on after_tick_loop, our effect on the game state is lost.
	# Because most setups tends to use state-syncronizer with input-sender.
	# state-syncronzier records on every tick and restores after tick loop.
	# 
	# To make sure our effect isnt lost to this order, we run logic on tick.
	NetworkTime.on_tick.connect(_on_tick)

# Whenever we receive input snapshot, we investigate and fetch _earliest_input tick
# This is later used to iterate over saved snapshots and emit signals.
func _on_received_input_snapshot(snapshot : _Snapshot) -> void:
	if snapshot.is_empty():
		return
	
	if not _ticks_that_has_new_snapshot.has(snapshot.tick):
		_ticks_that_has_new_snapshot.push_back(snapshot.tick)

# After a tick has been run
# Handle new snapshots
# Handle missing inputs.
# Handle local inputs.
#
# Since we are modifying InputSenders before emitting their signals,
# Their input properties will be messed up, this means users inputs wont be
# recorded properly on NetworkTime.after_tick.
# To prevent that, this function records their current state and restores at the
# end of this function.
func _on_tick(_delta : float, tick : int) -> void:
	# First save input-sender states.
	_save_input_sender_states()
	
	_handle_new_snapshots(tick)
	
	# We need to emit missing_input signal for old ticks.
	var missing_tick := tick - _missing_inputs_history_size
	if missing_tick >= 0:
		_handle_missing_tick(missing_tick)
	
	# DANGER
	# We use the latest recorded inputs, recorded on the previous after_tick.
	# This is explained on _ready comments.
	# Only once per gathered input: when an input is held back, nothing new
	# was recorded, see _record_and_send_inputs.
	if _pending_local_input_tick >= 0:
		_handle_local_inputs(_pending_local_input_tick)
		_pending_local_input_tick = -1
	
	# Logic is done, restore input-sender states.
	_restore_input_sender_states()
	
	# Now remove older history data that we keep.
	_trim_input_sender_histories(tick)

# Handles new input-sender snapshots.
# This function iterates over _ticks_that_has_new_snapshot. 
# If tick is within range of missing-input-history,
# applies/emits network_input.
# If its not within range,
# it applies/emits late_input.
# Clears _ticks_that_has_new_snapshot after done.
func _handle_new_snapshots(current_tick : int) -> void:
	if _ticks_that_has_new_snapshot.is_empty():
		return
	
	# So ticks are processed in ascending order.
	_ticks_that_has_new_snapshot.sort()
	
	
	for i in _ticks_that_has_new_snapshot:
		
		# This line saves processing because we fetch snapshot once per tick.
		var snapshot := _history_server._get_input_sender_snapshot(i)
		if not snapshot:
			# This situation shouldnt happen anyway.
			continue
		
		# Iterate over input senders and check if there is new input in tick
		for input_sender in _per_input_sender_history.keys():
			if not _is_there_new_input_for_input_sender(input_sender, i, snapshot):
				# No new input, we already processed this one.
				continue
			
			# Did not received before
			# If tick i past the missing_history_size, consider it late.
			input_sender._apply_snapshot_for_self(snapshot)
			if i <= current_tick - _missing_inputs_history_size:
				# Its a late input.
				input_sender.late_input.emit(i)
			else:
				# Its within range, consider it as network input.
				input_sender.network_input.emit(i)
			
			# Set as handled anyway for both situation.
			_set_input_received_for_input_sender(input_sender, i)
	
	_ticks_that_has_new_snapshot.clear()

# Iterates over snapshot for given tick
# Checks _per_input_sender_history for given tick.
# If input_sender did not received anything for this tick
# It assumes input is missing and emits input_missing.
# Call this function after calling _handle_new_snapshots.
# Param for tick must be the value of current_tick - missing_input_history_size.
func _handle_missing_tick(for_tick : int) -> void:
	
	for input_sender in _per_input_sender_history.keys():
		var input_sender_history := _per_input_sender_history[input_sender] as InputSenderHistory
		
		if not input_sender_history.did_receive_for_tick(for_tick):
			# We didnt receive anything for this input sender for this tick.
			# Try to find latest input and emit missing_input.
			
			var latest_tick := _history_server.get_latest_input_sender_for(
				input_sender._input_properties.get_subjects(), for_tick)
			
			if latest_tick >= 0:
				var snapshot := _history_server._get_input_sender_snapshot(latest_tick)
				if snapshot:
					input_sender._apply_snapshot_for_self(snapshot)
				else:
					# If no snapshot, we need to emit signal with -1
					latest_tick = -1
			
			# We may be able to find snapshot or not, emit anyway
			input_sender.missing_input.emit(for_tick, latest_tick)

# Iterates over input-senders and emits local input with latest recorded input available.
# Only does so if input-sender is authoritative peer.

# Duplicated comment from _ready:
#
# "For good reasons, We do logic and run InputSender signals on NetworkTime.on_tick
# This means local players wont have input information for their first tick.
# Its not really like await processframe but this will only add slight delay that wont have
# important effects on the game itself."
func _handle_local_inputs(for_tick : int) -> void:
	
	# Fetch snapshot once before loop to prevent unneccessary fetches.
	var snapshot := _history_server._get_input_sender_snapshot(for_tick)
	if not snapshot:
		# This shouldnt happen anyway.
		return
	
	for input_sender in _per_input_sender_history.keys():
		if input_sender.has_authority_over_input_nodes():
			# Its authoritative player.
			
			# We know that snapshots are recorded for each tick on NetworkTime.after_tick.
			# We can use it, no need to query get_latest_for here.
			input_sender._apply_snapshot_for_self(snapshot)
			input_sender.local_input.emit(for_tick)

# Saves all input-sender input properties.
# This is done before messing with properties.
func _save_input_sender_states() -> void:
	for input_sender in _per_input_sender_history.keys():
		input_sender._save_properties()

# Restores all input-sender input properties.
# This is done after messing with properties.
func _restore_input_sender_states() -> void:
	for input_sender in _per_input_sender_history.keys():
		input_sender._restore_properties()

# Records our own inputs and sends them to the host. Called after every tick.
#
# Host: the lead is always 0, so the input gathered on tick T is stamped T.
# Ticks go up by one, so every tick gets a new stamp, and none of the lead
# handling below happens. The only exception is a pause, where time jumps.
#
# Client: the input gathered on tick T is stamped T + lead, so it reaches the
# host before the host simulates that tick, see _SimulatorTimeTracker. While
# the lead stays the same, stamps go up by one every tick, just like ticks:
#
#   tick | lead | stamp | sent
#   100  | 5    | 105   | input of 100
#   101  | 5    | 106   | input of 101
#
# Lead grows (5 -> 6): tick 102 is stamped 108, so stamp 107 gets no input.
# The host needs an input for every tick it simulates, so 107 gets an input
# predicted from 106, then 108 gets the input of tick 102:
#
#   tick | lead | stamp | sent
#   102  | 6    | 108   | predicted input under 107, input of 102 under 108
#
# Lead shrinks (6 -> 5): tick 201 was stamped 207, and tick 202 would be
# stamped 207 too. What to do with the input of tick 202?
# - Send it under 207: no, 207 was already sent, and the host never lets a
#   client change an input it already has (cheating).
# - Send it under 208: no, tick 203 is stamped 208, so the clash just moves
#   to the next tick, and the next, forever.
# - Drop it: no, it may contain e.g. a fire press, which would be lost.
# A smaller lead means one stamp less, so two gathered inputs have to share
# one stamp. So we hold the input of tick 202 back, send nothing on this tick,
# and on the next tick send it merged with the input of tick 203 under 208:
#
#   tick | lead | stamp | sent
#   201  | 6    | 207   | input of 201
#   202  | 5    | 207   | nothing, input of 202 held back
#   203  | 5    | 208   | input of 202 merged with input of 203
#
# The lead changes by at most 1 tick per second, so this is rare. Predicting
# and merging is done by InputSender, so users can customize it.
func _record_and_send_inputs(_delta: float, tick: int) -> void:
	var stamped_tick := tick + SimulatorServer._get_input_lead()
	
	if _last_recorded_tick < 0:
		# First input, nothing to continue from
		_record_inputs(stamped_tick)
		return
	
	var next_tick := _last_recorded_tick + 1
	var skipped := stamped_tick - next_tick
	
	if skipped == 0:
		# Lead didn't change
		_record_inputs(stamped_tick)
	elif skipped == -1:
		# Lead shrank, this stamp is taken already. Hold this input back, and
		# merge it into the next one.
		_hold_inputs()
	elif skipped < -1:
		# Ticks went backwards, which only happens when NetworkTime restarts,
		# and we reset on that. Don't hold inputs forever, start over.
		_logger.warning(
			"Input stamp went back from @%d to @%d, starting over",
			[_last_recorded_tick, stamped_tick])
		_held_inputs.clear()
		_record_inputs(stamped_tick)
	elif skipped > MAX_FILLED_STAMPS:
		# Time jumped forward, e.g. after a pause, there's nothing to fill.
		_logger.debug(
			"Input stamp jumped from @%d to @%d, not filling",
			[_last_recorded_tick, stamped_tick])
		_record_inputs(stamped_tick)
	else:
		# Lead grew, fill the skipped stamps with predicted inputs
		_record_predicted_inputs(next_tick, stamped_tick)
		_record_inputs(stamped_tick)

# Records and sends the gathered inputs under the given stamp. If any inputs
# were held back, they're merged into the gathered ones first.
func _record_inputs(stamped_tick: int) -> void:
	if _held_inputs.is_empty():
		_record_and_send(stamped_tick)
	else:
		var merged_inputs : Dictionary[InputSender, Dictionary] = {}
		for input_sender in _held_inputs:
			if is_instance_valid(input_sender):
				merged_inputs[input_sender] = input_sender._get_merged_input(
					_held_inputs[input_sender], input_sender._get_input())
		_held_inputs.clear()
		
		_record_and_send_with(stamped_tick, merged_inputs)
	
	_pending_local_input_tick = stamped_tick

# Records and sends predicted inputs under the stamps from from_tick to
# to_tick (exclusive). All of them are predicted from the inputs recorded under
# the stamp before from_tick, same as the host does for missing inputs.
func _record_predicted_inputs(from_tick: int, to_tick: int) -> void:
	var predicted_inputs : Dictionary[InputSender, Dictionary] = {}
	
	for input_sender in _get_local_input_senders():
		# Apply the inputs recorded under the previous stamp to read them
		input_sender._save_properties()
		_history_server._restore_input_sender_subjects(
			input_sender._input_properties.get_subjects(), from_tick - 1)
		var last := input_sender._get_input()
		input_sender._restore_properties()
		
		predicted_inputs[input_sender] = input_sender._get_predicted_input(last)
	
	for stamped_tick in range(from_tick, to_tick):
		_record_and_send_with(stamped_tick, predicted_inputs)

# Holds back the gathered inputs, to be merged into the next ones.
func _hold_inputs() -> void:
	for input_sender in _get_local_input_senders():
		if _held_inputs.has(input_sender):
			# Already holding one, shouldn't happen since the lead changes
			# rarely. Merge, so nothing is lost.
			_held_inputs[input_sender] = input_sender._get_merged_input(
				_held_inputs[input_sender], input_sender._get_input())
		else:
			_held_inputs[input_sender] = input_sender._get_input()

# Applies the given inputs, records and sends them under the given stamp, then
# puts back the gathered inputs, so input scripts find them as they left them.
func _record_and_send_with(stamped_tick: int, inputs: Dictionary[InputSender, Dictionary]) -> void:
	for input_sender in inputs:
		input_sender._save_properties()
		input_sender._set_input(inputs[input_sender])
	
	_record_and_send(stamped_tick)
	
	for input_sender in inputs:
		input_sender._restore_properties()

func _record_and_send(stamped_tick: int) -> void:
	_history_server._record_input_sender(stamped_tick)
	_synchronization_server._synchronize_input_sender(stamped_tick)
	_last_recorded_tick = stamped_tick

# InputSenders whose inputs we gather and send.
func _get_local_input_senders() -> Array[InputSender]:
	var result : Array[InputSender] = []
	for input_sender in _per_input_sender_history.keys():
		if input_sender.has_authority_over_input_nodes():
			result.push_back(input_sender)
	return result

func _reset_stamps() -> void:
	_last_recorded_tick = -1
	_pending_local_input_tick = -1
	_held_inputs.clear()

func _register_input_sender(input_sender : InputSender) -> void:
	_per_input_sender_history[input_sender] = InputSenderHistory.new()

func _deregister_input_sender(input_sender : InputSender) -> void:
	_per_input_sender_history.erase(input_sender)
	_held_inputs.erase(input_sender)

# Helper that sets input received for param input sender on given tick.
func _set_input_received_for_input_sender(input_sender : InputSender, tick : int) -> void:
	var history : InputSenderHistory = _per_input_sender_history[input_sender] as InputSenderHistory
	if history:
		history.set_as_received_for_tick(tick)

## Check if there is a new input available for given input sender on given tick within matching snapshot.
func _is_there_new_input_for_input_sender(input_sender : InputSender, tick : int, snapshot : _Snapshot) -> bool:
	var history : InputSenderHistory = _per_input_sender_history[input_sender] as InputSenderHistory
	var received_before := history.did_receive_for_tick(tick)
	
	if received_before:
		return false
	
	# We need to check if snapshot has this input senders properties
	if snapshot:
		for property_entry in input_sender._property_entries:
			if snapshot.has_property(property_entry.node, property_entry.property):
				# There is new information available indeed
				return true
	
	# No new information
	return false

# Erases old input sender history data that we dont need anymore.
func _trim_input_sender_histories(current_tick : int) -> void:
	# Since we cant merge older history than input-sender-history
	# we can erase data older than that.
	
	var erase_ticks_older_than_inclusive : int = current_tick - _input_sender_history_size
	
	if erase_ticks_older_than_inclusive > 0:
		for input_sender_history in _per_input_sender_history.values():
			input_sender_history.erase_old_ticks(erase_ticks_older_than_inclusive)

func _init(p_history_server: _NetworkHistoryServer = null, p_synchronization_server: _NetworkSynchronizationServer = null):
	_history_server = p_history_server
	_synchronization_server = p_synchronization_server

## Inner class to remember and compare
## Did we receive any input before for given tick?
## stored for specific InputSender.
class InputSenderHistory extends RefCounted:
	
	# Maps ticks to bool (we received input before = true, never received = false)
	var _history : Dictionary = {}
	
	## Set param tick as received
	func set_as_received_for_tick(tick : int) -> void:
		_history[tick] = true
	
	## Check if we received input for given tick.
	## Returns false if we dont have information for that tick.
	func did_receive_for_tick(tick : int) -> bool:
		return _history.get(tick, false)
	
	## Erase old ticks that we dont need anymore.
	func erase_old_ticks(older_than_inclusive : int) -> void:
		var to_erase : Array[int] = []
		for tick in _history.keys():
			if tick <= older_than_inclusive:
				to_erase.push_back(tick)
		
		for erase_tick in to_erase:
			_history.erase(erase_tick)
