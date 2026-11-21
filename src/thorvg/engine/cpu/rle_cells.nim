## Cell storage of the scan converter (`rle.nim`): one x-sorted list of cells per row.
##
## Upstream (`_findCell`) walks the row list from its head on every lookup. A text line
## is a single shape with ~50 cells per row, so that walk dominated the frame time. Here
## every row also remembers the cell it touched last (`hint`) and the cells are doubly
## linked, so the walk starts next to the wanted x (outlines move along a row) and goes
## forward or backward. The set of cells and the x order of every row are exactly those
## of the upstream singly linked list, so the swept spans are identical (see H-perf-2).

type
  Cell* = object
    x*, next*, prev*: int32 ## `next`/`prev`: neighbour in the row, -1 = none
    cover*, area*: int

  CellGrid* = object
    cells*: seq[Cell]
    head, hint: seq[int32]  ## per row: first cell and last used cell, -1 = none

proc initGrid*(rows: int): CellGrid =
  result = CellGrid(head: newSeq[int32](rows), hint: newSeq[int32](rows))
  for y in 0 ..< rows:
    result.head[y] = -1
    result.hint[y] = -1

func firstCell*(g: CellGrid, row: int): int = int(g.head[row])

proc findCell*(g: var CellGrid, row, x: int): int =
  ## Index of the cell (row, x); creates it (zeroed) at its sorted place if missing.
  let want = int32(x)
  var prev = -1
  var cur = int(g.head[row])
  let h = int(g.hint[row])
  if h >= 0:
    if g.cells[h].x < want:
      prev = h
      cur = int(g.cells[h].next)
    else:
      cur = h
      prev = int(g.cells[h].prev)
      while prev >= 0 and g.cells[prev].x >= want:
        cur = prev
        prev = int(g.cells[prev].prev)
  while cur >= 0 and g.cells[cur].x <= want:
    if g.cells[cur].x == want:
      g.hint[row] = int32(cur)
      return cur
    prev = cur
    cur = int(g.cells[cur].next)
  result = g.cells.len
  g.cells.add Cell(x: want, next: int32(cur), prev: int32(prev))
  if prev < 0: g.head[row] = int32(result)
  else: g.cells[prev].next = int32(result)
  if cur >= 0: g.cells[cur].prev = int32(result)
  g.hint[row] = int32(result)
