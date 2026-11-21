## Node-level CSS cascade of the SVG loader: copying styles between nodes honouring
## `!important`, and looking up the style rules (`CssStyle` nodes) of the document.
##
## Ported from `modules/svg/tvgSvgCssStyle.cpp` (`cssCopyStyleAttr`, `cssFindStyleNode`,
## `cssUpdateStyle`). The `from`/`to` of the original are `src`/`dst` (`from` is a Nim
## keyword); null urls are "".

import std/options
import ./nodes

func importanceApplicable(toImp, fromImp: SvgStyleFlags, flag: SvgStyleFlag): bool =
  flag notin toImp and flag in fromImp

func takesPrecedence(src, dst: SvgStyleProperty, flag: SvgStyleFlag, overwrite: bool): bool =
  if overwrite: flag notin dst.flagsImportance or flag in src.flagsImportance
  else: flag notin dst.flags or importanceApplicable(dst.flagsImportance, src.flagsImportance, flag)

func markCopied(dst: var SvgStyleProperty, src: SvgStyleProperty, flag: SvgStyleFlag) =
  dst.flags.incl flag
  if flag in src.flagsImportance: dst.flagsImportance.incl flag

proc copyStyle(dst: var SvgStyleProperty, src: SvgStyleProperty, overwrite: bool) =
  ## `_copyStyle`: copies the properties of `src` that were explicitly set.
  let keep = if overwrite: dst.flagsImportance - src.flagsImportance else: dst.flags
  template wanted(set: bool, flag: SvgStyleFlag): bool =
    (set and flag notin keep) or importanceApplicable(dst.flagsImportance, src.flagsImportance, flag)
  template copyPaint(d, s: SvgPaint) =
    d.color = s.color
    d.none = s.none
    d.curColor = s.curColor
    if s.url.len > 0: d.url = s.url

  if wanted(src.curColorSet, SvgStyleFlag.Color):
    dst.color = src.color
    dst.curColorSet = true
    markCopied(dst, src, SvgStyleFlag.Color)
  if wanted(SvgStyleFlag.PaintOrder in src.flags, SvgStyleFlag.PaintOrder):
    dst.paintOrder = src.paintOrder
    markCopied(dst, src, SvgStyleFlag.PaintOrder)
  if wanted(SvgStyleFlag.Display in src.flags, SvgStyleFlag.Display):
    dst.display = src.display
    markCopied(dst, src, SvgStyleFlag.Display)
  # Fill
  if wanted(SvgFillFlag.Paint in src.fill.flags, SvgStyleFlag.Fill):
    copyPaint(dst.fill.paint, src.fill.paint)
    dst.fill.flags.incl SvgFillFlag.Paint
    markCopied(dst, src, SvgStyleFlag.Fill)
  if wanted(SvgFillFlag.Opacity in src.fill.flags, SvgStyleFlag.FillOpacity):
    dst.fill.opacity = src.fill.opacity
    dst.fill.flags.incl SvgFillFlag.Opacity
    markCopied(dst, src, SvgStyleFlag.FillOpacity)
  if wanted(SvgFillFlag.FillRule in src.fill.flags, SvgStyleFlag.FillRule):
    dst.fill.fillRule = src.fill.fillRule
    dst.fill.flags.incl SvgFillFlag.FillRule
    markCopied(dst, src, SvgStyleFlag.FillRule)
  # Stroke
  if wanted(SvgStrokeFlag.Paint in src.stroke.flags, SvgStyleFlag.Stroke):
    copyPaint(dst.stroke.paint, src.stroke.paint)
    dst.stroke.flags.incl SvgStrokeFlag.Paint
    markCopied(dst, src, SvgStyleFlag.Stroke)
  if wanted(SvgStrokeFlag.Opacity in src.stroke.flags, SvgStyleFlag.StrokeOpacity):
    dst.stroke.opacity = src.stroke.opacity
    dst.stroke.flags.incl SvgStrokeFlag.Opacity
    markCopied(dst, src, SvgStyleFlag.StrokeOpacity)
  if wanted(SvgStrokeFlag.Width in src.stroke.flags, SvgStyleFlag.StrokeWidth):
    dst.stroke.width = src.stroke.width
    dst.stroke.flags.incl SvgStrokeFlag.Width
    markCopied(dst, src, SvgStyleFlag.StrokeWidth)
  if wanted(SvgStrokeFlag.Dash in src.stroke.flags, SvgStyleFlag.StrokeDashArray) and
      SvgStrokeFlag.Dash in src.stroke.flags:
    dst.stroke.dash.array = src.stroke.dash.array
    dst.stroke.flags.incl SvgStrokeFlag.Dash
    markCopied(dst, src, SvgStyleFlag.StrokeDashArray)
  if wanted(SvgStrokeFlag.Cap in src.stroke.flags, SvgStyleFlag.StrokeLineCap):
    dst.stroke.cap = src.stroke.cap
    dst.stroke.flags.incl SvgStrokeFlag.Cap
    markCopied(dst, src, SvgStyleFlag.StrokeLineCap)
  if wanted(SvgStrokeFlag.Join in src.stroke.flags, SvgStyleFlag.StrokeLineJoin):
    dst.stroke.join = src.stroke.join
    dst.stroke.flags.incl SvgStrokeFlag.Join
    markCopied(dst, src, SvgStyleFlag.StrokeLineJoin)
  # Opacity and the rest
  if wanted(SvgStyleFlag.Opacity in src.flags, SvgStyleFlag.Opacity):
    dst.opacity = src.opacity
    markCopied(dst, src, SvgStyleFlag.Opacity)
  if wanted(SvgStyleFlag.BlendMode in src.flags, SvgStyleFlag.BlendMode):
    dst.blendMode = src.blendMode
    markCopied(dst, src, SvgStyleFlag.BlendMode)
  if wanted(SvgStyleFlag.ImageRendering in src.flags, SvgStyleFlag.ImageRendering):
    dst.imageRendering = src.imageRendering
    markCopied(dst, src, SvgStyleFlag.ImageRendering)
  if wanted(SvgStyleFlag.TextAnchor in src.flags, SvgStyleFlag.TextAnchor):
    dst.textAnchor = src.textAnchor
    markCopied(dst, src, SvgStyleFlag.TextAnchor)
  if wanted(SvgStyleFlag.AlignmentBaseline in src.flags, SvgStyleFlag.AlignmentBaseline):
    dst.alignmentBaseline = src.alignmentBaseline
    markCopied(dst, src, SvgStyleFlag.AlignmentBaseline)
  if wanted(SvgStyleFlag.DominantBaseline in src.flags, SvgStyleFlag.DominantBaseline):
    dst.dominantBaseline = src.dominantBaseline
    markCopied(dst, src, SvgStyleFlag.DominantBaseline)
  if wanted(SvgStyleFlag.FontWeight in src.flags, SvgStyleFlag.FontWeight):
    dst.fontWeight = src.fontWeight
    markCopied(dst, src, SvgStyleFlag.FontWeight)
  if wanted(SvgStyleFlag.LetterSpacing in src.flags, SvgStyleFlag.LetterSpacing):
    dst.letterSpacing = src.letterSpacing
    dst.letterSpacingRelative = src.letterSpacingRelative
    markCopied(dst, src, SvgStyleFlag.LetterSpacing)
  if wanted(SvgStyleFlag.WordSpacing in src.flags, SvgStyleFlag.WordSpacing):
    dst.wordSpacing = src.wordSpacing
    dst.wordSpacingRelative = src.wordSpacingRelative
    markCopied(dst, src, SvgStyleFlag.WordSpacing)

proc cssCopyStyleAttr*(dst, src: SvgNode, overwrite = false) =
  ## Copies transform, style and clip-path/mask references of `src` into `dst`. Without
  ## `overwrite` the values already set in `dst` win (unless `src` is `!important`).
  if src.transform.isSome and
      takesPrecedence(src.style, dst.style, SvgStyleFlag.Transform, overwrite):
    dst.transform = src.transform
    markCopied(dst.style, src.style, SvgStyleFlag.Transform)
  copyStyle(dst.style, src.style, overwrite)
  if SvgStyleFlag.ClipPath in src.style.flags and
      takesPrecedence(src.style, dst.style, SvgStyleFlag.ClipPath, overwrite):
    dst.style.clipPath.url = src.style.clipPath.url
    markCopied(dst.style, src.style, SvgStyleFlag.ClipPath)
  if SvgStyleFlag.Mask in src.style.flags and
      takesPrecedence(src.style, dst.style, SvgStyleFlag.Mask, overwrite):
    dst.style.mask.url = src.style.mask.url
    markCopied(dst.style, src.style, SvgStyleFlag.Mask)

func cssFindStyleNode*(style: SvgNode, title: string, kind: SvgNodeType): SvgNode =
  ## The rule of `kind` named `title` ("" = a rule without name), or nil.
  if style == nil: return nil
  for p in style.child:
    if p.kind == kind and p.id == title: return p
  nil

func cssFindStyleNode*(style: SvgNode, title: string): SvgNode =
  ## The class rule named `title`, or nil.
  if style == nil or title.len == 0: return nil
  for p in style.child:
    if p.kind == SvgNodeType.CssStyle and p.id == title: return p
  nil

proc cssUpdateStyle*(doc, style: SvgNode) =
  ## Applies the tag rules of `style` to every node of the tree below `doc`.
  for p in doc.child:
    let cssNode = cssFindStyleNode(style, "", p.kind)
    if cssNode != nil: cssCopyStyleAttr(p, cssNode)
    cssUpdateStyle(p, style)
