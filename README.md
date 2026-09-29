# lbmmon_json

Receive Ultra Messaging (UM) monitoring packets and print each one
as a single line of JSON on `stdout`.

<!-- mdtoc-start -->
<!-- mdtoc-end -->

## Copyright and License

All of the documentation and software included in this and any
other Informatica Ultra Messaging GitHub repository
Copyright (C) Informatica, 2026. All rights reserved.

Permission is granted to licensees to use
or alter this software for any purpose, including commercial applications,
according to the terms laid out in the Software License Agreement.

This source code example is provided by Informatica for educational
and evaluation purposes only.

THE SOFTWARE IS PROVIDED "AS IS" AND INFORMATICA DISCLAIMS ALL WARRANTIES
EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION, ANY IMPLIED WARRANTIES OF
NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A PARTICULAR
PURPOSE.  INFORMATICA DOES NOT WARRANT THAT USE OF THE SOFTWARE WILL BE
UNINTERRUPTED OR ERROR-FREE.  INFORMATICA SHALL NOT, UNDER ANY CIRCUMSTANCES,
BE LIABLE TO LICENSEE FOR LOST PROFITS, CONSEQUENTIAL, INCIDENTAL, SPECIAL OR
INDIRECT DAMAGES ARISING OUT OF OR RELATED TO THIS AGREEMENT OR THE
TRANSACTIONS CONTEMPLATED HEREUNDER, EVEN IF INFORMATICA HAS BEEN APPRISED OF
THE LIKELIHOOD OF SUCH DAMAGES.

## Repository

See https://github.com/UltraMessaging/mon_demo for code and documentation.

## Introduction

`lbmmon_json` is functionally similar to UM's `lbmmon.c` example
application, with one key difference: `lbmmon.c` decodes each
statistic by hand and hard-codes a formatted print for every
field, while `lbmmon_json` decodes each packet against its protobuf
schema and emits the whole record as JSON. As a result,
`lbmmon_json` does **not** need to be modified when UM adds new
statistics — new counters appear automatically in the JSON
output. It does, however, need to be **rebuilt** against `.proto`
files that describe the new counters. The motivation for writing
`lbmmon_json` was that `lbmmon.c` is no longer being updated.

`lbmmon_json` uses the `lbmmon` library's receive controller in PB
passthrough mode. The library subscribes to the UM statistics topic
(default `/29west/statistics`) on `lbmmon_json`'s behalf, validates
wire framing, and hands each packet's serialized protobuf payload
to a callback that decodes it and emits it as JSON. It is a
monitoring *consumer* — a small standalone diagnostic tool.

With `passthrough=convert`, CSV-format monitoring packets from
older UM installs are transparently converted to PB by the library
before the callback runs, so they appear as ordinary `packet_type`
records alongside packets from PB-formatted senders.

## Prerequisites

Building `lbmmon_json` requires the following items on the machine
that runs `bld.sh`. Claude checks and reports any missing ones
before starting a build.

- **A customer UM install**, e.g. `$HOME/UMP_6.17.1/`. This
  supplies `<lbm/lbmmon.h>` and `<lbm/lbmmonfmtpb.h>` (headers)
  and `liblbm.so` (runtime, including the `lbmmon` receive
  controller).
- **`.proto` schema files** for UM monitoring messages. The
  default (plan A) is that `bld.sh` fetches them from the UM
  online documentation
  (<https://ultramessaging.github.io/currdoc/doc/example/>) into
  `./proto/` on the first build and reuses the cache on
  subsequent builds. This requires `curl` (or `wget`) and
  outbound HTTPS at least once. The six files fetched are
  `ums_mon.proto`, `ump_mon.proto`, `dro_mon.proto`,
  `srs_mon.proto`, `um_mon_attributes.proto`, and
  `um_mon_control.proto`. UM keeps its monitoring schemas
  backwards compatible across releases, so the current online
  copies build a `lbmmon_json` that works against older UM
  installs too — there is no need to match the UM version you
  intend to monitor. Plan B, for offline / reproducible builds:
  set `UM_PROTO_DIR` in `lbm.sh` to a directory holding the six
  files locally (the UM doc package ships them, though the
  binary install does not), and `bld.sh` uses that directory
  verbatim instead of fetching.
- **Google Protocol Buffers C++ toolchain.** Any recent 3.x
  release works. On Ubuntu/Debian:
  ```
  sudo apt install protobuf-compiler libprotobuf-dev
  ```
  On macOS with Homebrew: `brew install protobuf`. Confirm with
  `protoc --version` and by checking that `libprotobuf` is
  linkable (`pkg-config --libs protobuf` or the header
  `<google/protobuf/util/json_util.h>`).
- **A C++17 compiler** (`g++` on Linux, Apple clang on macOS).
- **A valid UM license key.** Placed in `lbm.sh` (see below).

## Setup

First-time setup:

1. Copy the license/path template:
   ```
   cp lbm.sh.example lbm.sh
   ```
2. Edit `lbm.sh`:
   - Set `LBM_LICENSE_INFO` to your license key.
   - Set the base path to your UM install (the parent of the
     `Linux-glibc-…-x86_64/` directory).
   - Leave `UM_PROTO_DIR` unset (the default) to have `bld.sh`
     auto-fetch the current `.proto` files from the UM online
     documentation on the first build. Set it only if you want
     an offline / reproducible build — point it at a directory
     containing the six `.proto` files (from your UM doc
     package or a local archive).

`lbm.sh` is gitignored — it holds a license key and per-user
paths and never leaves the local checkout.

## Build

```
./bld.sh
```

`bld.sh` unconditionally regenerates the C++ protobuf bindings
under `generated/` from the `.proto` files in `$UM_PROTO_DIR`
(or, when `UM_PROTO_DIR` is unset, from `./proto/` — filling
the cache from the UM online docs on the first build), then
compiles `lbmmon_json.cc` (linked with `generated/*.pb.cc`) into
the `lbmmon_json` binary in the repo root. There is no incremental
build; every invocation is a fresh build.

Or ask Claude: *"build lbmmon_json"*. Claude will run `bld.sh`,
report any prerequisite gaps, and commit any repo-side changes.

## Run

```
./lbmmon_json                             # subscribe to /29west/statistics
./lbmmon_json -c um.xml                   # apply a UM configuration file
./lbmmon_json -t /29west/statistics/prod  # different statistics topic
./lbmmon_json -h                          # show usage
```

`lbmmon_json` prints one JSON object per line to `stdout` and runs
until you interrupt it (`Ctrl-C` sends `SIGINT`).

## Output

Every line is a self-contained JSON object with a millisecond
UTC timestamp (`ts`). There are two categories of line;
downstream tools tell them apart by grepping on the first
distinguishing key.

**Statistics packet** — the normal, successful case:

```json
{"ts":"2026-09-23T14:23:45.123Z","packet_type":"CONTEXT","attributes":{ ... },"data":{ ... }}
```

- `packet_type` is one of `SOURCE`, `RECEIVER`, `EVENT_QUEUE`,
  `CONTEXT`, `RECEIVER_TOPIC`, `WILDCARD_RECEIVER`, `UMESTORE`,
  `GATEWAY`, `UMDS`, `CONTROL_MESSAGE`, `SRS`.
- `attributes` is the JSON form of `UMMonAttributes` (identifies
  the emitting process: application source ID, timestamp,
  address, process ID, context instance, domain ID).
- `data` is the JSON form of the payload message. For `UMDS`
  packets there is no `attributes` or `data` field — a `note`
  field notes that no protobuf schema is shipped for UMDS.
  `CONTROL_MESSAGE` packets have no `attributes` submessage in
  their schema, so the envelope carries only `data`.

Filter statistics packets:
```
grep '"packet_type":' output.log
```

**Warning** — a packet reached the callback but couldn't be
decoded (payload parse failure, or a header packet-type outside
the recognized set):

```json
{"ts":"...","warning":"payload parse failed","reason":"UMSMonMsg","len":128}
```

Find all invalid packets:
```
grep '"warning":' output.log
```

Possible `warning` values:

| `warning`                       | Meaning                                                 |
|---------------------------------|---------------------------------------------------------|
| `payload parse failed`          | Data-block protobuf decode failed for the class dispatched from the header's packet type. |
| `unrecognized packet type`      | Header type field outside 0–10. Defensive; `lbmmon` normally filters these upstream. |

Signature/framing errors on the wire are handled by the `lbmmon`
library itself — they are logged to UM's log stream
(`Core-6033-12`) and never reach the callback, so `lbmmon_json`
doesn't emit warnings for them. Likewise, transport events
(BOS/EOS/loss) on the statistics topic are consumed inside the
library and do not appear in `lbmmon_json`'s output.

## Working with the output

Because every line is standalone JSON, streaming tools work
directly:

```
./lbmmon_json | jq -c 'select(.packet_type == "UMESTORE")'
./lbmmon_json | jq -c 'select(.warning) | {ts, warning, reason}'
./lbmmon_json | tee monitor.log | grep '"warning":'
```

The JSON uses `snake_case` field names matching the source
`.proto` schemas, and zero-valued primitive fields are omitted
to keep lines compact.

## End-to-end test

A self-contained local test lives in `test/`. It stands up a full
single-host UM topology on loopback — `lbmrd` (Mon TRD resolution),
SRS (TRD1 resolution), DRO (TRD1↔TRD2 bridge), persistent Store,
`umesrc` publisher, and `umercv` subscriber — with automatic
monitoring enabled and `lbmmon_json` in the role of the
monitoring-data receiver. Every component monitors in PB format
**except `umercv`, which monitors in CSV** — this exercises
`lbmmon`'s `passthrough=convert` path, which converts those CSV
packets to PB before they reach `lbmmon_json`'s callback.

Run it from the repo root after `./bld.sh` succeeds:

```
test/tst.sh
```

`tst.sh` `cd`s to its own directory on start, so it can be
invoked from anywhere — `cd test && ./tst.sh` works equivalently.
It detects the local IPv4 with `hostname -I` and substitutes it
into `um.xml.template`, `lbmrd.xml.template`, `srs.xml.template`,
and `store.xml.template`, so it runs on any single-host
Linux/WSL setup without editing.

The test takes roughly a minute end-to-end (a publisher run plus
sleeps to let the subscriber recover from the Store and
monitoring emit another cycle). When it finishes it prints
packet-type counts and up to five warning lines to stdout.

**Output files** — all written under `test/`:

- `test/lbmmon_json.jsonl` — every JSON line `lbmmon_json` emitted
  during the run. This is the artifact you inspect afterwards.
- `test/lbmmon_json.err` — stderr from `lbmmon_json`, which carries
  the `lbmmon` library's own log output (context creation, and
  `Core-10995-14x` BOS/EOS lines the library consumes
  internally).
- `test/lbmrd.log`, `test/srs.log`, `test/dro.log`,
  `test/store.log`, `test/umesrc.log`, `test/umercv.log` — logs
  from each supporting process, useful when the test fails.

Expected on a healthy run: `CONTEXT`, `RECEIVER`, `SOURCE`,
`RECEIVER_TOPIC`, `EVENT_QUEUE`, `UMESTORE`, `GATEWAY`, and
`SRS` records (counts depend on how many monitoring intervals
each component gets to emit); zero `warning` lines
— `umercv`'s CSV monitoring output is transparently converted
to PB by `lbmmon` and folded into the normal `packet_type`
stream, so it does not produce warnings.

**Locating errors.** `lbmmon_json` writes validation/decode errors
as `warning` JSON lines *to the same file as valid records* —
they don't go to `stderr`. If the finishing summary shows a
non-zero count under `=== warnings ===`, or you want to
double-check, grep the output file:

```
grep '"warning":' test/lbmmon_json.jsonl
```

Each warning line carries a `reason` and the packet `len` — see
the [Warning](#output) table above for what each `warning`
value means.

## Reporting problems

Open an issue with a sample of the output (a few lines each of
`packet_type` and `warning` if you have them) and a description
of what surprised you. Claude will read the issue, diagnose
against the design, and either fix `lbmmon_json` or update the
design and README.

## Maintenance model

This repository is maintained by **Claude** (the Anthropic
assistant) on the author's behalf. When you want a change,
describe what you want and Claude will make it. When you want a
build, either follow the steps in this README or ask Claude to
build it for you.

The design lives in [`design.md`](design.md).
