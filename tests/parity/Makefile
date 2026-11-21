# Build the ORIGINAL ThorVG CPU engine + SVG/PNG/TTF/raw loaders (no threads, no SIMD) and the parity driver.
# Usage (from project root, after env.ps1):  mingw32-make -f tests/parity/Makefile -j8
SHELL := cmd.exe
TVG   := upstream/thorvg
OUT   := build/cpp
SRC   := $(TVG)/src
CXX   := g++
CXXFLAGS := -std=c++14 -O2 -DNDEBUG -ffp-contract=off -fno-math-errno -Wno-unknown-pragmas -w \
  -DTVG_STATIC -DNOMINMAX \
  -I$(OUT)/include -I$(TVG)/inc -I$(SRC)/common -I$(SRC)/renderer -I$(SRC)/renderer/cpu_engine -I$(SRC)/modules \
  -I$(SRC)/modules/raw -I$(SRC)/modules/svg -I$(SRC)/modules/sfnt -I$(SRC)/modules/png/static -I$(SRC)/modules/jpg/static -I$(SRC)/modules/gif/load \
  -I$(SRC)/modules/webp/static

LIB_SRCS := \
  $(SRC)/common/tvgArray.cpp $(SRC)/common/tvgCompressor.cpp $(SRC)/common/tvgMath.cpp $(SRC)/common/tvgStr.cpp \
  $(addprefix $(SRC)/renderer/,tvgAccessor.cpp tvgAnimation.cpp tvgCanvas.cpp tvgFill.cpp tvgInitializer.cpp \
     tvgLoaderMgr.cpp tvgPaint.cpp tvgPicture.cpp tvgRender.cpp tvgSaver.cpp tvgScene.cpp tvgShape.cpp \
     tvgTaskScheduler.cpp tvgText.cpp) \
  $(addprefix $(SRC)/renderer/cpu_engine/,tvgSwBlendOp.cpp tvgSwFill.cpp tvgSwImage.cpp tvgSwMemPool.cpp \
     tvgSwPostEffect.cpp tvgSwRaster.cpp tvgSwRasterCore.cpp tvgSwRasterSimd.cpp tvgSwRenderer.cpp tvgSwRle.cpp \
     tvgSwShape.cpp tvgSwStroke.cpp tvgSwUtil.cpp) \
  $(SRC)/modules/raw/tvgRawLoader.cpp \
  $(addprefix $(SRC)/modules/svg/,tvgSvgBuilder.cpp tvgSvgCssStyle.cpp tvgSvgLoader.cpp tvgSvgPath.cpp tvgSvgUtil.cpp tvgXmlParser.cpp) \
  $(addprefix $(SRC)/modules/sfnt/,tvgSfntLoader.cpp tvgSfntReader.cpp tvgTtfReader.cpp) \
  $(addprefix $(SRC)/modules/png/static/,tvgLodePng.cpp tvgLodePngUtil.cpp tvgPngLoader.cpp) \
  $(addprefix $(SRC)/modules/jpg/static/,tvgJpgd.cpp tvgJpgLoader.cpp) \
  $(addprefix $(SRC)/modules/gif/load/,tvgGifDecoder.cpp tvgGifLoader.cpp) \
  $(SRC)/modules/webp/static/tvgWebpLoader.cpp \
  $(wildcard $(SRC)/modules/webp/static/dec/*.cpp $(SRC)/modules/webp/static/dsp/*.cpp \
     $(SRC)/modules/webp/static/utils/*.cpp)

OBJS := $(patsubst $(TVG)/%.cpp,$(OUT)/obj/%.o,$(LIB_SRCS))

all: $(OUT)/cpp_driver.exe

$(OUT)/obj/%.o: $(TVG)/%.cpp $(OUT)/include/config.h
	@if not exist "$(subst /,\,$(dir $@))" mkdir "$(subst /,\,$(dir $@))"
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/obj/driver.o: tests/parity/cpp_driver.cpp $(OUT)/include/config.h
	@if not exist "$(subst /,\,$(dir $@))" mkdir "$(subst /,\,$(dir $@))"
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/cpp_driver.exe: $(OBJS) $(OUT)/obj/driver.o
	$(CXX) $^ -o $@

clean:
	if exist "$(subst /,\,$(OUT))\obj" rmdir /s /q "$(subst /,\,$(OUT))\obj"
.PHONY: all clean