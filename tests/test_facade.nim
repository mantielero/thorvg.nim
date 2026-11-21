## Tests of the `thorvg` facade: convenience layer, PNG registration and fitPicture.
import std/unittest
import thorvg

suite "facade":
  test "check raises ThorvgError on failure":
    expect ThorvgError:
      check(Result.InvalidArguments)
    check(Result.Success)

  test "withStops copies the gradient":
    let g = linearGradient(0, 0, 10, 0)
    let h = g.withStops(colorStop(0, 1, 2, 3), colorStop(1, 4, 5, 6, 7))
    check g.stops.len == 0
    check h.stops.len == 2
    check h.stops[1].a == 7
    check h.stops[0].a == 255

  test "render a rectangle with the 3-argument fill":
    let c = newSwCanvas(8, 8)
    let s = newShape()
    check s.appendRect(2, 2, 4, 4)
    check s.fill(255, 0, 0)
    check c.add(s)
    c.render()
    let sf = swSurface(c)
    check sf.data[3 * 8 + 3] == 0xFFFF0000'u32
    check sf.data[0] == 0'u32

  test "fitPicture reports a missing file":
    expect ThorvgError:
      discard fitPicture("tests/data/does_not_exist.png", 10, 10)

  test "fitPicture scales and centers a png":
    let c = newSwCanvas(74, 29)
    check c.add(fitPicture("tests/data/png/rgba8.png", 74, 29))
    c.render()
    let sf = swSurface(c)
    var nonzero = 0
    for p in sf.data:
      if p != 0'u32: inc nonzero
    check nonzero > 0
    # 37x29 picture, scale 1, centered: the first and last 17 columns stay empty
    for y in 0 ..< 29:
      for x in [0, 16, 57, 73]: check sf.data[y * 74 + x] == 0'u32
