@tool
extends EditorPlugin

const MinimapOverlay := preload("res://addons/minimap_highlight/minimap_overlay.gd")

## Shared with the minimap bars. Fill and border only change the alpha.
const HIGHLIGHT := Color(1.0, 0.49, 0.08)
const SEARCH_FILL := Color(HIGHLIGHT.r, HIGHLIGHT.g, HIGHLIGHT.b, 0.55)
const SEARCH_BORDER := Color(HIGHLIGHT.r, HIGHLIGHT.g, HIGHLIGHT.b, 0.95)

var _active := false
var _script_editor: ScriptEditor
var _find_bar: Control
var _search_line: LineEdit
var _option_boxes: Array[CheckBox] = []
var _tab_containers: Array[TabContainer] = []
var _overlays: Dictionary = {}
## Last query actually drawn. Ctrl+F writes the selection with LineEdit.set_text(), which does not emit text_changed.
var _applied_search_active := false
var _applied_query := ""
var _applied_flags := 0
var _refreshing_matches := false


func _enter_tree() -> void:
	_active = true
	_script_editor = EditorInterface.get_script_editor()
	if _script_editor != null and not _script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		_script_editor.editor_script_changed.connect(_on_editor_script_changed)

	var settings := EditorInterface.get_editor_settings()
	if settings != null and not settings.settings_changed.is_connected(_on_settings_changed):
		settings.settings_changed.connect(_on_settings_changed)

	call_deferred("_setup")


func _exit_tree() -> void:
	_active = false
	_teardown()


func _setup() -> void:
	if not _active:
		return
	if _script_editor == null or not is_instance_valid(_script_editor):
		_script_editor = EditorInterface.get_script_editor()
	if _script_editor == null:
		push_warning("Minimap Highlight: script editor is not available.")
		return
	if not _script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		_script_editor.editor_script_changed.connect(_on_editor_script_changed)
	_bind_find_bar()
	if _find_bar == null:
		push_warning("Minimap Highlight could not find the script editor find bar.")
	_bind_tab_containers(_script_editor)
	_attach_open_editors()
	_refresh_matches()


func _teardown() -> void:
	if _search_line != null and is_instance_valid(_search_line):
		if _search_line.text_changed.is_connected(_on_search_text_changed):
			_search_line.text_changed.disconnect(_on_search_text_changed)
		if _search_line.draw.is_connected(_on_search_line_drawn):
			_search_line.draw.disconnect(_on_search_line_drawn)
	_search_line = null

	if _find_bar != null and is_instance_valid(_find_bar):
		if _find_bar.visibility_changed.is_connected(_on_find_bar_visibility_changed):
			_find_bar.visibility_changed.disconnect(_on_find_bar_visibility_changed)
	_find_bar = null

	for box in _option_boxes:
		if is_instance_valid(box) and box.toggled.is_connected(_on_search_option_toggled):
			box.toggled.disconnect(_on_search_option_toggled)
	_option_boxes.clear()

	for tabs in _tab_containers:
		if is_instance_valid(tabs) and tabs.tab_changed.is_connected(_on_tab_changed):
			tabs.tab_changed.disconnect(_on_tab_changed)
	_tab_containers.clear()

	if _script_editor != null and is_instance_valid(_script_editor):
		if _script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
			_script_editor.editor_script_changed.disconnect(_on_editor_script_changed)

	var settings := EditorInterface.get_editor_settings()
	if settings != null and settings.settings_changed.is_connected(_on_settings_changed):
		settings.settings_changed.disconnect(_on_settings_changed)

	var editors: Array = _overlays.keys()
	for code_edit in editors:
		_detach_code_edit(code_edit)
	_overlays.clear()
	_script_editor = null


func _bind_find_bar() -> void:
	if _find_bar != null and is_instance_valid(_find_bar):
		return

	var bar := _locate_find_bar(_script_editor)
	if bar == null:
		return

	_find_bar = bar
	_search_line = _first_line_edit(bar)
	if _search_line != null and not _search_line.text_changed.is_connected(_on_search_text_changed):
		_search_line.text_changed.connect(_on_search_text_changed)
	# set_text() skips text_changed. The box still redraws, which is how a selection reaches Ctrl+F.
	if _search_line != null and not _search_line.draw.is_connected(_on_search_line_drawn):
		_search_line.draw.connect(_on_search_line_drawn)
	if not _find_bar.visibility_changed.is_connected(_on_find_bar_visibility_changed):
		_find_bar.visibility_changed.connect(_on_find_bar_visibility_changed)

	_option_boxes = _collect_checkboxes(bar)
	for box in _option_boxes:
		if not box.toggled.is_connected(_on_search_option_toggled):
			box.toggled.connect(_on_search_option_toggled)


func _locate_find_bar(root: Node) -> Control:
	var named := _find_node_by_class(root, "FindReplaceBar")
	if named is Control:
		return named

	# Older or renamed editor builds: the bar is the box that owns Find and Replace.
	var matches: Array[Control] = []
	_collect_structural_bars(root, matches)
	if matches.is_empty():
		return null
	for bar in matches:
		var line := _first_line_edit(bar)
		if line != null and line.placeholder_text.to_lower() == "find":
			return bar
	return matches[0]


func _find_node_by_class(node: Node, native_class: String) -> Node:
	if node.get_class() == native_class:
		return node
	for child in node.get_children():
		var found := _find_node_by_class(child, native_class)
		if found != null:
			return found
	return null


func _collect_structural_bars(node: Node, matches: Array[Control]) -> void:
	if (
		node is HBoxContainer
		and _count_of_type(node, "LineEdit") >= 2
		and _count_of_type(node, "CheckBox") >= 2
	):
		matches.append(node)
	for child in node.get_children():
		_collect_structural_bars(child, matches)


func _bind_tab_containers(node: Node) -> void:
	if node is TabContainer:
		var tabs := node as TabContainer
		if not _tab_containers.has(tabs):
			_tab_containers.append(tabs)
			if not tabs.tab_changed.is_connected(_on_tab_changed):
				tabs.tab_changed.connect(_on_tab_changed)
	for child in node.get_children():
		_bind_tab_containers(child)


func _attach_open_editors() -> void:
	if _script_editor == null:
		return
	for editor in _script_editor.get_open_script_editors():
		var base := editor.get_base_editor()
		if base is CodeEdit:
			_attach_code_edit(base)


func _attach_code_edit(code_edit: CodeEdit) -> void:
	if _overlays.has(code_edit) and is_instance_valid(_overlays[code_edit]):
		_apply_search_colors(code_edit)
		_refresh_breakpoints(code_edit)
		return

	var overlay: MinimapOverlay = MinimapOverlay.new()
	overlay.code_edit = code_edit
	code_edit.add_child(overlay)
	_overlays[code_edit] = overlay
	_apply_search_colors(code_edit)

	var text_callback := _on_code_text_changed.bind(code_edit)
	if not code_edit.text_changed.is_connected(text_callback):
		code_edit.text_changed.connect(text_callback)
	var breakpoint_callback := _on_breakpoint_toggled.bind(code_edit)
	if not code_edit.breakpoint_toggled.is_connected(breakpoint_callback):
		code_edit.breakpoint_toggled.connect(breakpoint_callback)
	var resized_callback := _on_code_resized.bind(code_edit)
	if not code_edit.resized.is_connected(resized_callback):
		code_edit.resized.connect(resized_callback)
	var draw_callback := _on_code_drawn.bind(code_edit)
	if not code_edit.draw.is_connected(draw_callback):
		code_edit.draw.connect(draw_callback)
	if not code_edit.tree_exiting.is_connected(_on_code_edit_exiting.bind(code_edit)):
		code_edit.tree_exiting.connect(_on_code_edit_exiting.bind(code_edit))

	var v_scroll := code_edit.get_v_scroll_bar()
	if v_scroll != null:
		var scroll_callback := _on_code_scrolled.bind(code_edit)
		if not v_scroll.value_changed.is_connected(scroll_callback):
			v_scroll.value_changed.connect(scroll_callback)
	var h_scroll := code_edit.get_h_scroll_bar()
	if h_scroll != null and not h_scroll.visibility_changed.is_connected(resized_callback):
		h_scroll.visibility_changed.connect(resized_callback)

	_refresh_breakpoints(code_edit)
	overlay.fit_to_minimap()


func _detach_code_edit(code_edit: CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		_overlays.erase(code_edit)
		return

	var text_callback := _on_code_text_changed.bind(code_edit)
	if code_edit.text_changed.is_connected(text_callback):
		code_edit.text_changed.disconnect(text_callback)
	var breakpoint_callback := _on_breakpoint_toggled.bind(code_edit)
	if code_edit.breakpoint_toggled.is_connected(breakpoint_callback):
		code_edit.breakpoint_toggled.disconnect(breakpoint_callback)
	var resized_callback := _on_code_resized.bind(code_edit)
	if code_edit.resized.is_connected(resized_callback):
		code_edit.resized.disconnect(resized_callback)
	var draw_callback := _on_code_drawn.bind(code_edit)
	if code_edit.draw.is_connected(draw_callback):
		code_edit.draw.disconnect(draw_callback)
	var exit_callback := _on_code_edit_exiting.bind(code_edit)
	if code_edit.tree_exiting.is_connected(exit_callback):
		code_edit.tree_exiting.disconnect(exit_callback)

	var v_scroll := code_edit.get_v_scroll_bar()
	if v_scroll != null:
		var scroll_callback := _on_code_scrolled.bind(code_edit)
		if v_scroll.value_changed.is_connected(scroll_callback):
			v_scroll.value_changed.disconnect(scroll_callback)
	var h_scroll := code_edit.get_h_scroll_bar()
	if h_scroll != null and h_scroll.visibility_changed.is_connected(resized_callback):
		h_scroll.visibility_changed.disconnect(resized_callback)

	_remove_search_colors(code_edit)
	var overlay := _overlays.get(code_edit) as MinimapOverlay
	if overlay != null and is_instance_valid(overlay):
		overlay.queue_free()
	_overlays.erase(code_edit)


func _refresh_matches() -> void:
	if not _active or _refreshing_matches:
		return
	_refreshing_matches = true
	if _find_bar == null or not is_instance_valid(_find_bar):
		_bind_find_bar()
	_drop_stale_editors()
	_attach_open_editors()

	var active := _current_code_edit()
	var lines := PackedInt32Array()
	if _search_is_active() and active != null:
		lines = _match_lines(active, _search_line.text, _search_flags())

	for code_edit in _overlays.keys():
		if not is_instance_valid(code_edit):
			continue
		_apply_search_colors(code_edit)
		var overlay := _overlays[code_edit] as MinimapOverlay
		if overlay == null or not is_instance_valid(overlay):
			continue
		if code_edit == active:
			overlay.set_matches(lines)
		else:
			overlay.set_matches(PackedInt32Array())
		_refresh_breakpoints(code_edit)
		overlay.fit_to_minimap()
	_remember_search_state()
	_refreshing_matches = false


func _search_is_active() -> bool:
	return (
		_find_bar != null
		and is_instance_valid(_find_bar)
		and _find_bar.visible
		and _search_line != null
		and is_instance_valid(_search_line)
		and not _search_line.text.is_empty()
	)


func _search_flags() -> int:
	# Tree order matches FindReplaceBar construction: Match Case, Whole Words, then Selection Only.
	# Selection Only does not change the in-editor match highlight. Backwards is a navigation flag.
	var flags := 0
	if _option_boxes.size() >= 1 and is_instance_valid(_option_boxes[0]) and _option_boxes[0].button_pressed:
		flags |= TextEdit.SEARCH_MATCH_CASE
	if _option_boxes.size() >= 2 and is_instance_valid(_option_boxes[1]) and _option_boxes[1].button_pressed:
		flags |= TextEdit.SEARCH_WHOLE_WORDS
	return flags


static func _match_lines(code_edit: CodeEdit, query: String, flags: int) -> PackedInt32Array:
	var lines := PackedInt32Array()
	if query.is_empty() or code_edit.get_line_count() == 0:
		return lines

	# One hit per line is enough for a minimap stripe. search() wraps the document,
	# so a hit on an earlier line means there is nothing left ahead of the cursor.
	var line := 0
	while line < code_edit.get_line_count():
		var found := code_edit.search(query, flags, line, 0)
		if found.x < 0 or found.y < line:
			break
		lines.append(found.y)
		line = found.y + 1
	return lines


func _current_code_edit() -> CodeEdit:
	if _script_editor == null or not is_instance_valid(_script_editor):
		return null
	var editor := _script_editor.get_current_editor()
	if editor == null:
		return null
	var base := editor.get_base_editor()
	if base is CodeEdit:
		return base
	return null


func _apply_search_colors(code_edit: CodeEdit) -> void:
	code_edit.add_theme_color_override(&"search_result_color", SEARCH_FILL)
	code_edit.add_theme_color_override(&"search_result_border_color", SEARCH_BORDER)


func _remove_search_colors(code_edit: CodeEdit) -> void:
	code_edit.remove_theme_color_override(&"search_result_color")
	code_edit.remove_theme_color_override(&"search_result_border_color")


func _reapply_search_colors() -> void:
	if not _active:
		return
	for code_edit in _overlays.keys():
		if not is_instance_valid(code_edit):
			continue
		_apply_search_colors(code_edit)
		code_edit.queue_redraw()
		_refresh_breakpoints(code_edit)
		var overlay := _overlays[code_edit] as MinimapOverlay
		if overlay != null and is_instance_valid(overlay):
			overlay.fit_to_minimap()


func _drop_stale_editors() -> void:
	var stale: Array = []
	for code_edit in _overlays.keys():
		if not is_instance_valid(code_edit):
			stale.append(code_edit)
	for code_edit in stale:
		_overlays.erase(code_edit)


func _on_editor_script_changed(_script: Script) -> void:
	_setup()


func _on_tab_changed(_tab: int) -> void:
	_attach_open_editors()
	_refresh_matches()


func _on_search_text_changed(_text: String) -> void:
	if _search_state_changed():
		_refresh_matches()


func _on_search_line_drawn() -> void:
	if _search_state_changed():
		_refresh_matches()


func _search_state_changed() -> bool:
	return (
		_search_is_active() != _applied_search_active
		or _current_search_query() != _applied_query
		or _search_flags() != _applied_flags
	)


func _current_search_query() -> String:
	if _search_line == null or not is_instance_valid(_search_line):
		return ""
	return _search_line.text


func _remember_search_state() -> void:
	_applied_search_active = _search_is_active()
	_applied_query = _current_search_query()
	_applied_flags = _search_flags()


func _on_search_option_toggled(_pressed: bool) -> void:
	_refresh_matches()


func _on_find_bar_visibility_changed() -> void:
	# show() runs before the selection is copied into the box.
	call_deferred("_refresh_matches")


func _on_settings_changed() -> void:
	# The script editor writes the faint theme color back during this signal. Run after that.
	call_deferred("_reapply_after_editor_theme")


func _reapply_after_editor_theme() -> void:
	call_deferred("_reapply_search_colors")


func _on_breakpoint_toggled(_line: int, code_edit: CodeEdit) -> void:
	_refresh_breakpoints(code_edit)


func _refresh_breakpoints(code_edit: CodeEdit) -> void:
	if not is_instance_valid(code_edit):
		return
	var overlay := _overlays.get(code_edit) as MinimapOverlay
	if overlay == null or not is_instance_valid(overlay):
		return
	overlay.set_breakpoints(code_edit.get_breakpointed_lines())


func _on_code_text_changed(code_edit: CodeEdit) -> void:
	if code_edit == _current_code_edit():
		_refresh_matches()
	else:
		_refresh_breakpoints(code_edit)


func _on_code_resized(code_edit: CodeEdit) -> void:
	var overlay := _overlays.get(code_edit) as MinimapOverlay
	if overlay != null and is_instance_valid(overlay):
		overlay.fit_to_minimap()


func _on_code_scrolled(_value: float, code_edit: CodeEdit) -> void:
	var overlay := _overlays.get(code_edit) as MinimapOverlay
	if overlay != null and is_instance_valid(overlay):
		overlay.queue_redraw()


func _on_code_drawn(code_edit: CodeEdit) -> void:
	var overlay := _overlays.get(code_edit) as MinimapOverlay
	if overlay != null and is_instance_valid(overlay) and overlay.has_marks():
		overlay.queue_redraw()


func _on_code_edit_exiting(code_edit: CodeEdit) -> void:
	# The editor frees the CodeEdit, which frees the overlay with it.
	_overlays.erase(code_edit)


func _first_line_edit(node: Node) -> LineEdit:
	if node is LineEdit:
		return node
	for child in node.get_children():
		var found := _first_line_edit(child)
		if found != null:
			return found
	return null


func _collect_checkboxes(node: Node) -> Array[CheckBox]:
	var boxes: Array[CheckBox] = []
	_collect_checkboxes_into(node, boxes)
	return boxes


func _collect_checkboxes_into(node: Node, boxes: Array[CheckBox]) -> void:
	if node is CheckBox:
		boxes.append(node)
	for child in node.get_children():
		_collect_checkboxes_into(child, boxes)


func _count_of_type(node: Node, type_name: String) -> int:
	var count := 0
	if node.get_class() == type_name:
		count += 1
	for child in node.get_children():
		count += _count_of_type(child, type_name)
	return count
