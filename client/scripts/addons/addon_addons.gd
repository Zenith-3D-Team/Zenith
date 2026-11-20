extends RefCounted
## api.addons (1.7): what an add-on may ask about the others, for its addon.json's dependencies
## (docs/ADDONS.md). Read-only. Calls between add-ons aren't promised yet: reaching another add-on's
## node works today but may change.

var _api: WeakRef  # the add-on's API object: weak, so the part doesn't keep it alive


func _init(api) -> void:
	_api = weakref(api)


## The version of the add-on with this id while it runs ("0.3.0"), "" when it isn't running (not
## installed, switched off, refused). An optional dependency is checked with it.
func version(id: String) -> String:
	var api = _api.get_ref()
	if api == null or api._host == null:
		return ""
	return api._host.running_version(id)
