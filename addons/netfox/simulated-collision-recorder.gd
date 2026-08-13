extends RefCounted
class_name _SimulatedCollisionRecorder

## Helper class for recording simulation aware areas and collision shapes.
##
## Used by [_SimulatorServer] internally.

const SIMULATION_AWARE_GROUP := &"SimulationAware"

var _logger := NetfoxLogger._for_netfox("SimulationAwareServer")
var _history_size : int = ProjectSettings.get_setting("netfox/simulator/history_limit", 64)

# tick -> Dictionary[Node, _Snapshot]
var _snapshots_by_tick : Dictionary[int, Dictionary] = {}
var _tracked_nodes : Array[Node] = []

# Inner helper struct to hold data together.
class _CollisionSnapshot:
		var transform : Transform3D
		var disabled : bool
		var monitoring : bool
		var monitorable : bool
		var collision_layer : int
		var is_area : bool

## Setup needs to be called by owner node.
## Because refcounted classes doesnt have access to scene tree.
func setup(tree: SceneTree) -> void:
	tree.node_added.connect(_on_node_added)
	for node in tree.get_nodes_in_group(SIMULATION_AWARE_GROUP):
		_track(node)

func _on_node_added(node: Node) -> void:
	if node.is_in_group(SIMULATION_AWARE_GROUP):
		_track(node)

func _track(node: Node) -> void:
	if node in _tracked_nodes:
		return
	
	if not (node is CollisionShape3D or node is Area3D):
		_logger.warning(
			"Node %s is in %s group but isn't a CollisionShape3D or Area3D, ignoring." + \
			"Dont add nodes that isnt CollisionShape or Area to this group.",
			[node.name, SIMULATION_AWARE_GROUP]
		)
		return
	
	_tracked_nodes.push_back(node)
	node.tree_exiting.connect(_untrack.bind(node), CONNECT_ONE_SHOT)

func _untrack(node: Node) -> void:
	_tracked_nodes.erase(node)
	# Old snapshot dicts aren't scrubbed here.
	# Because we remove invalid nodes from our _tracked_nodes on record_tick()

func record_tick(tick: int) -> void:
	var snapshot_dict : Dictionary[Node, _CollisionSnapshot] = {}
	
	var i := _tracked_nodes.size() - 1
	while i >= 0:
		var node := _tracked_nodes[i]
		
		if not is_instance_valid(node):
			# Remove invalid nodes and continue.
			_tracked_nodes.remove_at(i)
			i -= 1
			continue

		var snap := _CollisionSnapshot.new()
		snap.transform = node.global_transform
		if node is CollisionShape3D:
			snap.disabled = node.disabled
		else: # Area3D
			snap.is_area = true
			snap.monitoring = node.monitoring
			snap.monitorable = node.monitorable
			snap.collision_layer = node.collision_layer
		
		# Save per node data.
		snapshot_dict[node] = snap
		i -= 1

	# Save snapshot by tick.
	_snapshots_by_tick[tick] = snapshot_dict

func restore_tick(tick: int) -> void:
	if not _snapshots_by_tick.has(tick):
		_logger.warning(
			"No snapshot recorded for tick %s (predates history / never recorded). Skipping restore.",
			[tick]
		)
		return

	var snapshot_dict := _snapshots_by_tick[tick] as Dictionary

	for node in _tracked_nodes:
		if not is_instance_valid(node):
			continue

		if snapshot_dict.has(node):
			var snap : _Snapshot = snapshot_dict[node]
			node.global_transform = snap.transform
			if node is CollisionShape3D:
				node.disabled = snap.disabled
			elif snap.is_area:
				node.monitoring = snap.monitoring
				node.monitorable = snap.monitorable
				node.collision_layer = snap.collision_layer
		else:
			# Not tracked yet at this historical tick -> didn't exist in the sim yet.
			_exclude_from_collision(node)

func _exclude_from_collision(node: Node) -> void:
	if node is CollisionShape3D:
		node.disabled = true
	elif node is Area3D:
		node.monitoring = false
		node.monitorable = false
		node.collision_layer = 0

func capture_live_state() -> Dictionary:
	var live : Dictionary[Node, _CollisionSnapshot] = {}
	var i := _tracked_nodes.size() - 1
	while i >= 0:
		var node := _tracked_nodes[i]
		if not is_instance_valid(node):
			_tracked_nodes.remove_at(i)
			i -= 1
			continue

		var snap := _CollisionSnapshot.new()
		snap.transform = node.global_transform
		if node is CollisionShape3D:
			snap.disabled = node.disabled
		else:
			snap.is_area = true
			snap.monitoring = node.monitoring
			snap.monitorable = node.monitorable
			snap.collision_layer = node.collision_layer

		live[node] = snap
		i -= 1
	return live

func restore_snapshot(snapshot_dict: Dictionary) -> void:
	for node in snapshot_dict:
		if not is_instance_valid(node):
			continue
		var snap : _CollisionSnapshot = snapshot_dict[node]
		node.global_transform = snap.transform
		if node is CollisionShape3D:
			node.disabled = snap.disabled
		elif snap.is_area:
			node.monitoring = snap.monitoring
			node.monitorable = snap.monitorable
			node.collision_layer = snap.collision_layer

func trim_before(beginning: int) -> void:
	for tick in _snapshots_by_tick.keys():
		if tick < beginning:
			_snapshots_by_tick.erase(tick)
