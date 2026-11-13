extends RefCounted
## Whether Zenith's interface is hidden: one flag for every way of hiding it. F11 and the Cinematic
## camera's clean shot hide it through an add-on's api.view.hide_interface (addon_host.gd), and
## --clean-shot through main.gd; each says so here under its own reason.
##
## The parts of the interface drawn in the 3D world (GROUP: alert_icons.gd's alert icons over
## entities, fluids_power.gd's no-power icons) follow the flag every frame themselves, so an icon made
## after the interface hid (alerts arriving later, another surface, a new game's nodes) stays hidden
## too. The add-on host used to hide only the icons that existed at that moment, and the B-roll filmed
## the alert triangles made after it.

const GROUP := &"f3d_hide_with_interface"

static var _by := {}  # reason -> true while it wants the interface hidden


static func set_hidden(reason: StringName, on: bool, tree: SceneTree = null) -> void:
	if on:
		_by[reason] = true
	else:
		_by.erase(reason)
	if tree != null:
		apply(tree)


static func hidden() -> bool:
	return not _by.is_empty()


## Shows or hides a node of the interface drawn in the world as the flag says (call it each frame).
static func follow(node: Node3D) -> void:
	var want := not hidden()
	if node.visible != want:
		node.visible = want


## Every node in GROUP at once, so a change shows on the next frame drawn.
static func apply(tree: SceneTree) -> void:
	for n: Node in tree.get_nodes_in_group(GROUP):
		if n is Node3D:
			follow(n as Node3D)
