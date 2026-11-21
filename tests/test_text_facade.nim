## Text through the public facade (`import thorvg` only) with the shared demo scene.

import std/unittest
import thorvg
import ../examples/text_scene

const Font = "tests/data/upstream/PublicSans-Regular.ttf"

suite "text facade":
  test "demo scene renders pixels":
    let c = newSwCanvas(400, 300)
    buildText(c, Font)
    c.render()
    var nonzero = 0
    for p in swSurface(c).data:
      if p != 0: inc nonzero
    check nonzero > 5000

  test "missing font raises":
    let c = newSwCanvas(100, 100)
    expect ThorvgError:
      buildText(c, "tests/data/nope.ttf")

  test "custom headline replaces the first line":
    let a = newSwCanvas(400, 300)
    buildText(a, Font)
    a.render()
    let b = newSwCanvas(400, 300)
    buildText(b, Font, "Other")
    b.render()
    check swSurface(a).data != swSurface(b).data

  test "text api is exported":
    check loadFont(Font) == Result.Success
    let t = newText()
    check t.font() == Result.Success
    check t.size(20) == Result.Success
    check t.text("Hi") == Result.Success
    check t.length == 2
    t.unload()
