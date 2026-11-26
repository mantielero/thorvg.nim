## Built-in AOT expression packs. Register generated packs here.
import registry
import ../../../generated/expr_audio_layer

proc registerBuiltinExprPacks*(r: var ExprRegistry) =
  r.register(exprAudioLayerHash, exprAudioLayerR)
