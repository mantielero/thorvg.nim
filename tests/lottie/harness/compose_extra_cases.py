"""
tests/lottie/harness/compose_extra_cases.py

Casos adicionales para aislar causas en el backlog de ty5. Se usan solo
propiedades que ya pasan (escala y opacidad) para separar:
  - grouping/anchor de la posicion/rotacion del range animator,
  - la matematica del selector (shape, offset, rangos) de la composicion,
  - el tracking del wrap.
"""

def add_extra(CASES, lot, animator, selector, animated, MULTI, F0):
    # Referencia de sensibilidad para los casos de tracking
    CASES["base_track"] = (lot("AB CD AB"), F0)

    # 1) Grouping y anchor sin posicion ni rotacion: solo escala alrededor del
    #    anchor de grupo. Si fallan, el problema es de grouping/anchor; si pasan,
    #    el fallo de group_* era p/r del range animator.
    for g, name in ((1, "chars"), (2, "words"), (3, "lines"), (4, "all")):
        CASES[f"groupscale_{name}"] = (lot(
            MULTI, group=g, anchor=(10, 5),
            animators=[animator(selector(based=1), s=[120, 120])]), F0)

    # 2) Selector con opacidad en lugar de posicion: aisla shape/offset/rango.
    CASES["range_factor_half_opacity"] = (lot(
        "ABCDA", animators=[animator(selector(start=0, end=50, shape=2), o=50)]), F0)
    CASES["range_triangle_edge_opacity"] = (lot(
        "ABCDA", animators=[animator(selector(start=0, end=100, shape=3), o=50)]), F0)
    CASES["range_offset_animated_opacity"] = (lot(
        "ABCDA", animators=[animator(
            selector(start=0, end=50, shape=3,
                     offset=animated([(0, 0), (59, 100)])), o=50)]),
        [0, 15, 30, 45, 59])

    # 3) Tracking separado del wrap: sin caja, y con caja lo bastante ancha
    #    para que no haya salto de linea.
    WIDE = (0, 0, 600, 120)
    CASES["track_pos_nowrap"]  = (lot("AB CD AB", tr=200), F0)
    CASES["track_neg_nowrap"]  = (lot("AB CD AB", tr=-100), F0)
    CASES["track_pos_boxwide"] = (lot("AB CD AB", tr=200, box=WIDE), F0)
    CASES["track_neg_boxwide"] = (lot("AB CD AB", tr=-100, box=WIDE), F0)

    # 4) Sonda: que hace C++ 1.2.0 con justify fuera de 0-2 (j=3). Sin base de
    #    sensibilidad; se lee a mano el volcado y se documenta en la matriz.
    CASES["probe_justify_3"] = (lot(
        "AB CD AB\rCD AB", j=3, box=(0, 0, 300, 120)), F0)
