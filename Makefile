# Builds lib/rime_core.so (lib/rime_core.dll on Windows).
#
# Only a C compiler is needed: the Lua and librime headers are vendored in
# src/, librime itself is loaded at runtime, and the Lua symbols come from
# the Neovim executable.

CC ?= cc
CFLAGS ?= -O2
WARN := -Wall -Wextra -Wno-unused-parameter

ifeq ($(OS),Windows_NT)
  TARGET := lib/rime_core.dll
  # Neovim on Windows links LuaJIT as lua51.dll; point LUA_LIB at it
  # (or at an import library) when it is not on the linker path.
  LUA_LIB ?= -llua51
  LDFLAGS_MODULE := -shared $(LUA_LIB)
else
  TARGET := lib/rime_core.so
  UNAME_S := $(shell uname -s)
  ifeq ($(UNAME_S),Darwin)
    LDFLAGS_MODULE := -bundle -undefined dynamic_lookup
  else
    LDFLAGS_MODULE := -shared -pthread -ldl
  endif
  CFLAGS += -fPIC -fvisibility=hidden -pthread
endif

SRC := src/rime_core.c
HDR := src/rime/rime_api.h src/lua/lua.h src/lua/lauxlib.h src/lua/luaconf.h

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC) $(HDR)
	@mkdir -p lib
	$(CC) $(CFLAGS) $(WARN) -std=c99 -D_GNU_SOURCE -o $@ $(SRC) $(LDFLAGS_MODULE) $(LDFLAGS)

clean:
	rm -f lib/rime_core.so lib/rime_core.dll

.PHONY: test
test: all
	nvim --headless -u NONE -c "luafile tests/run.lua"
