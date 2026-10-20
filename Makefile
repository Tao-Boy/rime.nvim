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

# On Nix (NixOS, nix-darwin, Nix on another system), librime and the Rime
# data are not where programs look for them.  Rather than having them
# added to the system configuration, fetch them from nixpkgs here:
# lib/nix-librime and lib/nix-rime-data link to their store paths (and
# keep them from being garbage-collected), next to rime_core.so, which
# looks there.  <nixpkgs> is the system's nixpkgs, whose glibc is the one
# of the system's Neovim.  NIX=0 skips this; NIXPKGS selects another
# package set (an expression for nix-build).
HAVE_NIX := $(if $(wildcard /nix/store),$(shell command -v nix-build >/dev/null 2>&1 && echo 1))
NIX ?= $(if $(HAVE_NIX),1,0)
NIXPKGS ?= <nixpkgs>
NIX_LINKS := lib/nix-librime lib/nix-rime-data

.PHONY: all clean

all: $(TARGET)
ifeq ($(NIX),1)
all: $(NIX_LINKS)
endif

# A failure (offline, no channel) is not fatal: rime_core still looks in
# the Nix profiles and in /nix/store.
lib/nix-%:
	@mkdir -p lib
	nix-build '$(NIXPKGS)' -A $* -o $@ --no-build-output >/dev/null \
	  || nix --extra-experimental-features 'nix-command flakes' build nixpkgs#$* --out-link $@ \
	  || echo 'warning: could not get $* from nixpkgs' >&2

$(TARGET): $(SRC) $(HDR) Makefile
	@mkdir -p lib
	$(CC) $(CFLAGS) $(WARN) -std=c99 -o $@ $(SRC) $(LDFLAGS_MODULE) $(LDFLAGS)

clean:
	rm -f lib/rime_core.so lib/rime_core.dll $(wildcard lib/nix-*)

.PHONY: test
test: all
	nvim --headless -u NONE -c "luafile tests/run.lua"
