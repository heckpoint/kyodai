class_name GridGeometry
extends RefCounted

## Pure grid scroll geometry — the ONLY implementation of the line/slot/page
## offset formula that grid_offset_identity_test pins. Layout, visual sync,
## focus-follow, and scroll anchoring all consume this; nothing re-derives
## offsets. All inputs are pushed by the grid (_sync_geometry); every function
## is a pure computation from them. No scene-tree access, no caches.

enum Mode { GRID, LIST, CAROUSEL }

# --- Inputs (pushed by VirtualScrollGridContainer._sync_geometry) ---
var mode: int = Mode.GRID
var vertical: bool = true
var separation: int = 0
var staggered: bool = false      # staggered brick rows (vertical GRID only)
var paginated: bool = false      # page groups (GRID only)
var page_preview: float = 0.0    # adjacent-page pixels visible at snapped positions
var items_per_line: int = 1
var stride: float = 0.0          # scroll-axis pitch (card scroll size + separation)
var card_scroll: float = 0.0     # card size on the scroll axis
var focus_overflow: float = 0.0  # scroll-axis focus-grow overflow
var viewport: float = 0.0        # available size on the scroll axis
var total_items: int = 0         # padded item count

# --- Line mapping -------------------------------------------------------------

## Whole lines (rows when vertical, columns when horizontal) that fit in the
## viewport on the scroll axis.
func lines_per_page() -> int:
	if stride <= 0.0:
		return 1
	var lpp := maxi(1, int((viewport + separation) / stride))
	# Staggered pages must start on a full (even) row so every page has the
	# same composition: round down to an even line count.
	if staggered and lpp >= 2:
		lpp -= lpp % 2
	return lpp

## Total line count (rows/columns) across all items.
func total_lines() -> int:
	if items_per_line <= 0 or total_items <= 0:
		return 0
	if staggered:
		return stagger_line_for_index(total_items - 1) + 1
	return ceili(float(total_items) / items_per_line)

# --- Staggered rows -------------------------------------------------------------
# In staggered mode (vertical GRID only) rows alternate capacities: even rows
# hold N cards, odd rows hold N-1 and start half a stride to the right via a
# leading half-cell spacer in the flow. All scroll-axis math stays line-based
# (uniform row stride); only the index<->line mapping changes.

## Items in one full two-row stagger unit (N even-row + N-1 odd-row).
func stagger_pair_count() -> int:
	return maxi(1, 2 * items_per_line - 1)

func stagger_line_for_index(idx: int) -> int:
	var pair := stagger_pair_count()
	var unit := int(idx / float(pair))
	var rem: int = idx - unit * pair
	return unit * 2 + (0 if rem < items_per_line else 1)

## Cards on a staggered row (N on even rows, N-1 on offset/odd rows).
func stagger_line_capacity(line: int) -> int:
	return items_per_line - (1 if line % 2 == 1 else 0)

func stagger_first_index_for_line(line: int) -> int:
	var pair := stagger_pair_count()
	var unit := int(line / 2.0)
	return unit * pair + (items_per_line if line % 2 == 1 else 0)

## Line an item sits on (uniform mapping unless staggered).
func line_for_index(idx: int, ipl: int = -1) -> int:
	if staggered:
		return stagger_line_for_index(idx)
	if ipl <= 0:
		ipl = items_per_line
	return int(float(idx) / ipl)

## First item index of a line (uniform mapping unless staggered).
func first_index_for_line(line: int, ipl: int = -1) -> int:
	if staggered:
		return stagger_first_index_for_line(line)
	if ipl <= 0:
		ipl = items_per_line
	return line * ipl

# --- Pagination (GRID mode only) -------------------------------------------------

## Scroll-axis extent of one page's cards (no trailing separation).
func page_content_size() -> float:
	return lines_per_page() * stride - separation

## Blank space between page groups in the scroll direction. At a snapped page
## position, size the gap so the next page starts page_preview pixels inside the
## viewport (and the previous page leaves the same preview at the leading edge).
## The minimum keeps the full-line flow spacer representable; unusually tight
## pages gracefully reduce the preview instead of creating negative geometry.
func page_gap() -> float:
	if not paginated:
		return 0.0
	var desired_gap := page_center_offset() - page_preview - separation
	return maxf(separation + 1.0, desired_gap)

## Scroll-axis distance from one page start to the next (page + gap).
func page_period() -> float:
	if not paginated:
		return 0.0
	return lines_per_page() * stride + page_gap()

## Scroll offset subtracted from page-start targets so each page sits centered
## in the viewport (blank slack split into balanced gutters on both sides).
func page_center_offset() -> float:
	if not paginated:
		return 0.0
	return maxf(0.0, (viewport - page_content_size()) / 2.0)

func page_count() -> int:
	var lpp := lines_per_page()
	var tl := total_lines()
	if lpp <= 0 or tl <= 0:
		return 1
	return int((tl - 1) / float(lpp)) + 1

## Leading blank pad before slot 0: equals the center offset so page 0's
## centered target lands exactly at scroll 0 instead of clamping flush-left.
func page_leading_pad() -> float:
	return page_center_offset()

## Trailing blank pad after the last line: enough for even a PARTIAL last page
## to reach its centered scroll target (its content plus this pad spans the
## same centered extent as a full page).
func page_trailing_pad() -> float:
	if not paginated:
		return 0.0
	var lpp := lines_per_page()
	var tl := total_lines()
	if stride <= 0.0 or lpp <= 0 or tl <= 0:
		return 0.0
	var last_page := int((tl - 1) / float(lpp))
	var lines_in_last: int = tl - last_page * lpp
	var last_content := lines_in_last * stride - separation
	return (page_content_size() - last_content) + page_center_offset()

## Page index containing slot `idx`.
func page_for_index(idx: int) -> int:
	if items_per_line <= 0:
		return 0
	return int(float(line_for_index(idx)) / lines_per_page())

## Snapped scroll position for page `page` (centered, clamped to range).
## With the leading pad in the slot transform, targets are simply k * period.
func page_scroll_target(page: int) -> float:
	page = clampi(page, 0, page_count() - 1)
	return clampf(page * page_period(), 0.0, (page_count() - 1) * page_period())

## Nearest snapped page target to `pos`.
func snap_to_page_target(pos: float) -> float:
	var period := page_period()
	if period <= 0.0:
		return pos
	var page := clampi(int(round(pos / period)), 0, page_count() - 1)
	return page * period

# --- Slot positions ----------------------------------------------------------------

## Scroll-axis pixel position where slot `idx` begins.
func slot_position(idx: int, ipl: int = -1, p_stride: float = -1.0) -> float:
	if ipl <= 0:
		ipl = items_per_line
	if p_stride <= 0.0:
		p_stride = stride
	var line := line_for_index(idx, ipl)
	var pos := line * p_stride
	if paginated:
		# Page groups are separated by a spacer gap in the scroll direction;
		# the leading pad lets page 0 sit centered at scroll 0.
		pos += page_leading_pad() + int(line / float(lines_per_page())) * page_gap()
	return pos

## Inverse of the (page-gapped) slot position transform.
func line_for_scroll(pos: float) -> int:
	if stride <= 0.0:
		return 0
	if not paginated:
		return int(pos / stride)
	var lpp := lines_per_page()
	var period := page_period()
	if period <= 0.0:
		return int(pos / stride)
	var rel := pos - page_leading_pad()
	if rel <= 0.0:
		return 0
	var page := int(rel / period)
	var rem := rel - page * period
	# A position inside the gap clamps to the last line of that page.
	var line_in_page := mini(int(rem / stride), lpp - 1)
	return page * lpp + maxi(0, line_in_page)

## Scroll-axis position of the end of the last line, including the trailing
## pad that lets partial last pages center (no trailing page gap).
func content_end() -> float:
	if total_items <= 0:
		return 0.0
	return slot_position(total_items - 1) + stride + page_trailing_pad()

# --- Scroll targets ------------------------------------------------------------------

## Maximum meaningful scroll offset against COMPUTED content geometry.
func max_scroll() -> float:
	return maxf(0.0, content_end() + 2.0 * focus_overflow - viewport)

## Clamp against computed geometry — never the live scrollbar range, which is
## stale for a frame after a library shrink / layout recalc.
func clamp_to_range(offset: float) -> float:
	if paginated:
		return clampf(offset, 0.0, (page_count() - 1) * page_period())
	return clampf(offset, 0.0, max_scroll())

## UNCLAMPED scroll offset that places the center of slot `idx` at the
## viewport center. Cards grow around their center when focused, so the
## unfocused card size is the correct centering basis. Page alignment wins
## over centering when paginated. Callers clamp (the grid routes through its
## range clamp, which has a live-scrollbar fallback for untrustworthy states).
func center_offset(idx: int) -> float:
	if paginated:
		return page_scroll_target(page_for_index(idx))
	return slot_position(idx) + focus_overflow + card_scroll / 2.0 - viewport / 2.0

## UNCLAMPED minimal-delta focus follow: where to scroll when card `idx`
## gains focus. Edge-triggered — no scroll until the card's visual bounds
## (including its focus grow) cross `margin` at a viewport edge. Returns
## `current` when no scroll is needed; center_mode centers instead of
## minimal-sliding. Callers clamp.
func reveal_offset(idx: int, current: float, margin: float, center_mode: bool) -> float:
	if paginated:
		# Page alignment wins over centering: focus moves within the current
		# page need no scroll; crossing a boundary jumps to the new page.
		return page_scroll_target(page_for_index(idx))
	var card_start := slot_position(idx) + focus_overflow
	var card_end := card_start + card_scroll
	# Visual bounds of the focused card (it grows around its center).
	var visual_start := card_start - focus_overflow
	var visual_end := card_end + focus_overflow

	var view_start := current + margin
	var view_end := current + viewport - margin

	# On cramped screens the focused card (including its grow overflow) plus
	# both margins can exceed the viewport, making both-edge containment
	# impossible. Without a stability out, the minimal-delta branch below
	# ping-pongs between top-align and bottom-align on every same-row hop.
	var fits := (visual_end - visual_start) <= viewport - 2.0 * margin
	if fits:
		if visual_start >= view_start and visual_end <= view_end:
			return current
	elif absf(visual_start - view_start) < 1.0 or absf(visual_end - view_end) < 1.0:
		# Doesn't fit: stable once either edge is flush.
		return current

	if center_mode:
		return center_offset(idx)

	# Minimal scroll — slide the card just back inside the margin.
	var target := current
	if visual_start < view_start:
		target = visual_start - margin
	elif visual_end > view_end:
		target = visual_end + margin - viewport
	return target
