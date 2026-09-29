#!/bin/sh
# bld.sh - build lbmmon_json on Linux/macOS.
#
# Single-pass build. Every invocation regenerates the C++ protobuf
# bindings under generated/ from the .proto files in $UM_PROTO_DIR,
# then compiles lbmmon_json.cc and generated/*.pb.cc into ./lbmmon_json.
#
# If $UM_PROTO_DIR is unset, bld.sh defaults to a local ./proto/
# cache and auto-fetches any missing .proto files from the UM
# online documentation:
#   https://ultramessaging.github.io/currdoc/doc/example/<name>.proto

set -u

PROTO_FILES="ums_mon.proto ump_mon.proto dro_mon.proto srs_mon.proto \
um_mon_attributes.proto um_mon_control.proto"
PROTO_URL_BASE="https://ultramessaging.github.io/currdoc/doc/example"

# -------- Locate lbm.sh --------
if [ ! -f ./lbm.sh ]; then
  echo "bld.sh: ./lbm.sh not found. Copy lbm.sh.example and edit it." >&2
  exit 1
fi
. ./lbm.sh

# -------- Prerequisites --------
if [ -z "${LBM:-}" ] || [ ! -d "$LBM" ]; then
  echo "bld.sh: LBM not set, or dir '$LBM' missing. Edit lbm.sh." >&2
  exit 1
fi
if [ ! -f "$LBM/include/lbm/lbmmon.h" ]; then
  echo "bld.sh: '$LBM/include/lbm/lbmmon.h' missing. Wrong UM install?" >&2
  exit 1
fi

# -------- Resolve UM_PROTO_DIR (fetch on demand if unset) --------
if [ -z "${UM_PROTO_DIR:-}" ]; then
  UM_PROTO_DIR="./proto"
  mkdir -p "$UM_PROTO_DIR"

  # Pick a downloader. curl is on virtually every Linux/macOS box;
  # fall back to wget if curl isn't installed.
  if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL -o"
  elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -q -O"
  else
    echo "bld.sh: neither 'curl' nor 'wget' on PATH; cannot fetch .proto files." >&2
    echo "         Install one, or set UM_PROTO_DIR in lbm.sh to a local copy." >&2
    exit 1
  fi

  for F in $PROTO_FILES; do
    if [ ! -f "$UM_PROTO_DIR/$F" ]; then
      echo "Fetching $F from $PROTO_URL_BASE/"
      if ! $FETCH "$UM_PROTO_DIR/$F" "$PROTO_URL_BASE/$F"; then
        echo "bld.sh: failed to download '$PROTO_URL_BASE/$F'" >&2
        rm -f "$UM_PROTO_DIR/$F"
        exit 1
      fi
    fi
  done
fi

if [ ! -d "$UM_PROTO_DIR" ]; then
  echo "bld.sh: UM_PROTO_DIR '$UM_PROTO_DIR' is not a directory." >&2
  exit 1
fi
for F in $PROTO_FILES; do
  if [ ! -f "$UM_PROTO_DIR/$F" ]; then
    echo "bld.sh: missing '$UM_PROTO_DIR/$F'" >&2
    exit 1
  fi
done

if ! command -v protoc >/dev/null 2>&1; then
  echo "bld.sh: 'protoc' not on PATH. Install protobuf-compiler." >&2
  exit 1
fi

# -------- Generate C++ bindings --------
echo "Regenerating C++ protobuf bindings from $UM_PROTO_DIR"
mkdir -p generated
rm -f generated/*.pb.h generated/*.pb.cc
protoc --cpp_out=generated -I "$UM_PROTO_DIR" "$UM_PROTO_DIR"/*.proto
if [ $? -ne 0 ]; then echo "bld.sh: protoc failed" >&2; exit 1; fi

# -------- Compile --------
if [ "`uname`" = "Darwin" ]; then
  PLATFORM_LIBS="-lpthread"
else
  PLATFORM_LIBS="-pthread -lrt"
fi

echo "Building lbmmon_json"
g++ -std=c++17 -Wall -g \
    -I "$LBM/include" -I "$LBM/include/lbm" -I generated \
    -o lbmmon_json lbmmon_json.cc generated/*.pb.cc \
    -L "$LBM/lib" -llbm \
    -lprotobuf -lm $PLATFORM_LIBS
if [ $? -ne 0 ]; then echo "bld.sh: g++ failed" >&2; exit 1; fi

echo "Success"
