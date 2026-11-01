@tool
extends Control

## One minimap row. TextEdit uses a private char size of (1, 2) plus 1px of spacing.
const ROW_HEIGHT := 3

## Same orange as the script-editor match fill, drawn opaque so it stays bright over syntax pixels.
const BAR_COLOR := Color(1.0, 0.49, 0.08, 1.0)

var code_edit: CodeEdit

var _match_lines: Dictionary = {}
var _breakpoint_lines: Dictionary = {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func has_matches() -> bool:
	return not _match_lines.is_empty()


func has_marks() -> bool:
	return has_matches() or not _breakpoint_lines.is_empty()


func set_matches(lines: PackedInt32Array) -> void:
	_match_lines.clear()
	for line in lines:
		_match_lines[line] = true
	queue_redraw()


func set_breakpoints(lines: PackedInt32Array) -> void:
	_breakpoint_lines.clear()
	for line in lines:
		_breakpoint_lines[line] = true
	queue_redraw()


func fit_to_minimap() -> void:
	if code_edit == null or not is_instance_valid(code_edit) or not code_edit.is_drawing_minimap():
		hide()
		return

	var style := _current_stylebox()
	var right := int(style.get_margin(SIDE_RIGHT))
	var minimap_width := code_edit.get_minimap_width()
	# TextEdit draws the minimap at xmargin_end + 2, after reserving minimap_width past the right margin.
	var x := code_edit.size.x - float(right) - float(minimap_width) + 2.0
	if code_edit.is_layout_rtl():
		x = float(right) - 2.0

	var height := code_edit.size.y - style.get_minimum_size().y
	var h_scroll := code_edit.get_h_scroll_bar()
	if h_scroll != null and h_scroll.visible:
		height -= h_scroll.size.y

	position = Vector2(x, 0.0)
	size = Vector2(minimap_width, maxf(height, 0.0))
	show()
	queue_redraw()


func _draw() -> void:
	if not has_marks() or code_edit == null or not is_instance_valid(code_edit):
		return
	if not code_edit.is_drawing_minimap() or size.x <= 0.0 or size.y <= 0.0 or code_edit.get_line_count() == 0:
		return

	# Hit-testing subtracts the stylebox top margin. The minimap pixels themselves start at y = 0.
	var top_margin := _current_stylebox().get_margin(SIDE_TOP)
	var visible_matches := _visible_lines(_match_lines)
	var visible_breakpoints := _visible_lines(_breakpoint_lines)
	var breakpoint_color := _breakpoint_color()
	var last_line := code_edit.get_line_count() - 1
	var last_line_rows := 0
	var last_line_limit := code_edit.get_line_wrap_count(last_line) + 1 if last_line >= 0 else 0
	var sample_x := int(position.x) + 1
	var y := 0
	while y < size.y:
		var line := code_edit.get_minimap_line_at_pos(Vector2i(sample_x, int(position.y + float(y) + top_margin)))
		# Positions past the last drawn row clamp to the final line. Stop once that line's real rows are used up.
		if line == last_line:
			last_line_rows += 1
			if last_line_rows > last_line_limit:
				break
		if visible_matches.has(line):
			draw_rect(Rect2(0, y, size.x, ROW_HEIGHT), BAR_COLOR)
		# A line that is both a match and a breakpoint stays the breakpoint color.
		if visible_breakpoints.has(line):
			draw_rect(Rect2(0, y, size.x, ROW_HEIGHT), breakpoint_color)
		y += ROW_HEIGHT


func _breakpoint_color() -> Color:
	var color := code_edit.get_theme_color(&"breakpoint_color")
	color.a = 1.0
	return color


func _visible_lines(source: Dictionary) -> Dictionary:
	var visible := {}
	var line_count := code_edit.get_line_count()
	for line in source:
		var header := int(line)
		if header < 0 or header >= line_count:
			continue
		if code_edit.has_method("get_folded_line_header"):
			var folded: int = code_edit.get_folded_line_header(header)
			if folded >= 0 and folded < line_count:
				header = folded
		else:
			# 4.7 no longer binds get_folded_line_header. A backward visible-line
			# offset of N lands on the nearest visible line at line - N + 1.
			var back := code_edit.get_next_visible_line_offset_from(header, -1)
			if back > 1:
				header = maxi(header - back + 1, 0)
		visible[header] = true
	return visible


func _current_stylebox() -> StyleBox:
	# TextEdit::_get_current_stylebox uses normal while editable, read_only otherwise.
	if code_edit.editable:
		return code_edit.get_theme_stylebox(&"normal")
	return code_edit.get_theme_stylebox(&"read_only")
