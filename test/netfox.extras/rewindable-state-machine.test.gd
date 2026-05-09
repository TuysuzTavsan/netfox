extends VestTest

func get_suite_name() -> String:
	return "RewindableStateMachine"

var state_machine: RewindableStateMachine
var first_state: RewindableState
var other_state: RewindableState

func before_case(__):
	state_machine = RewindableStateMachine.new()
	first_state = mock(RewindableState)
	other_state = mock(RewindableState)

	# Setup mock answers
	when(first_state.can_enter).then_return(true)
	when(first_state._on_enter).then_answer(func(__): pass)
	when(first_state._on_exit).then_answer(func(__): pass)
	when(first_state._on_tick).then_answer(func(__): pass)
	when(first_state._on_display_enter).then_answer(func(__): pass)
	when(first_state._on_display_exit).then_answer(func(__): pass)

	when(other_state.can_enter).then_return(true)
	when(other_state._on_enter).then_answer(func(__): pass)
	when(other_state._on_exit).then_answer(func(__): pass)
	when(other_state._on_tick).then_answer(func(__): pass)
	when(other_state._on_display_enter).then_answer(func(__): pass)
	when(other_state._on_display_exit).then_answer(func(__): pass)

	# Set state names
	first_state.name = "First State"
	other_state.name = "Other State"

	# Add states as children - RSM will pick them up when added
	# **NOTE**: Make sure to set owner if spawning states manually, otherwise
	# RSM won't pick them up
	state_machine.add_child(first_state); first_state.owner = state_machine
	state_machine.add_child(other_state); other_state.owner = state_machine

	# TODO(vest): TestingSceneTree
	await Vest._scene_tree.process_frame
	Vest._scene_tree.root.add_child(state_machine, true)

func test_should_start_empty():
	expect_empty(state_machine.state)

func test_should_notify_new_state_on_enter():
	capture_signal(first_state.entering_state, 3)

	# Enter first state
	state_machine.transition("First State")

	# Check for event
	expect_not_empty(get_signal_emissions(first_state.entering_state))
	expect_empty(get_calls_of(first_state.can_enter))
	expect_equal(get_calls_of(first_state._on_enter), [[null, 0]])

func test_on_enter_should_prevent_transition():
	other_state.entering_state.connect(
		func(_new_state, _tick, prevent):
			prevent.call()
	)

	# Enter first state
	state_machine.transition("First State")

	# Try to enter second state
	expect_false(state_machine.transition("Other State"), "Transition should have failed!")
	expect_equal(state_machine.state, "First State")

func test_on_exit_should_prevent_transition():
	first_state.exiting_state.connect(
		func(_new_state, _tick, prevent):
			prevent.call()
	)

	# Enter first state
	state_machine.transition("First State")

	# Try to enter second state
	expect_false(state_machine.transition("Other State"), "Transition should have failed!")
	expect_equal(state_machine.state, "First State")

func test_can_enter_should_prevent_transition():
	state_machine.state = "First State"

	# Register a more specific answer so the mock will use that
	when(other_state.can_enter)\
		.with_args([first_state])\
		.then_return(func(__): return false)

	# Try to enter second state
	expect_false(state_machine.transition("Other State"), "Transition should have failed!")
	expect_equal(state_machine.state, "First State")

func test_should_call_tick():
	capture_signal(first_state.state_ticked, 3)

	# Set state
	state_machine.transition("First State")

	# Run a rollback tick
	state_machine._rollback_tick(0.16, 0, true)

	# Tick should have been called
	expect_equal(get_calls_of(first_state.tick), [[0.16, 0, true]], "Wrong method call!")
	expect_equal(get_signal_emissions(first_state.on_tick), [[0.16, 0, true]], "Wrong signal!")

func test_should_notify_display_state():
	state_machine.state = "First State"

	capture_signal(first_state.display_entered, 2)
	capture_signal(first_state.display_exited, 2)
	capture_signal(other_state.display_entered, 2)

	# First loop, display enters First State
	NetworkMocks.in_network_tick_loop(func():
		state_machine.transition("First State")
	)
	expect_not_empty(get_signal_emissions(first_state.display_entered))
	expect_not_empty(get_calls_of(first_state._on_display_enter))

	# Second loop, display enters Other State
	NetworkMocks.in_network_tick_loop(func():
		state_machine.transition("Other State")
	)

	expect_not_empty(get_signal_emissions(first_state.display_entered))
	expect_not_empty(get_signal_emissions(other_state.display_entered))

	expect_not_empty(get_calls_of(first_state._on_display_exit))
	expect_not_empty(get_calls_of(other_state._on_display_enter))

func after_case(__):
	state_machine.queue_free()
