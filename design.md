# Design: lbmmon_json

**Status:** design
**Target UM version:** 6.17.1

`lbmmon_json` subscribes to the UM statistics topic (default
`/29west/statistics`) and emits one JSON object per packet on
`stdout`. It uses the `lbmmon` receive controller in PB
passthrough mode: the library handles network I/O, header
validation, and attribute-block deserialization, and hands the
callback the raw serialized payload bytes.

## 1. Purpose

A small standalone program that:

1. Creates an `lbmmon_rctl_t` receive controller in PB passthrough
   mode against the statistics topic.
2. For each packet delivered to the passthrough callback, decodes
   the payload as protobuf, converts the decoded message to a JSON
   string, and writes the JSON to `stdout` (one JSON object per
   line).
3. Anything that fails to decode is also emitted to `stdout`, as a
   JSON line with a `warning` field so downstream tooling can
   filter or highlight it.

With `passthrough=convert`, CSV-format monitoring packets from
older UM installs are transparently converted to PB by the library
before the callback runs and appear as ordinary `packet_type`
records. This means `lbmmon_json` handles both PB-formatted and
CSV-formatted senders without special-case code.

Registering **only** the passthrough callback is deliberate. With
`passthrough=on`/`convert`, the PB deserializers short-circuit
before unpacking, so any per-object-type callbacks
(`LBMMON_RCTL_SOURCE_CALLBACK`, `LBMMON_RCTL_UMESTORE_CALLBACK`,
etc.) would never fire. The shipped `example/lbmmon.c` registers
all of them for demonstration purposes; `lbmmon_json` intentionally
does not follow that pattern.

## 2. Language: C++

The task's core operation is "convert a protobuf message to JSON."
This maps 1-to-1 onto
`google::protobuf::util::MessageToJsonString()` — a single call in
the Google C++ protobuf library.

The C protobuf binding UM ships (`protobuf-c`, with
`libprotobuf-c.so` in the customer install) does **not** have a
message-to-JSON function. Doing this in pure C would require
either (a) pulling in a third-party library such as
`protobuf2json-c`, or (b) writing a descriptor-walking JSON
serializer by hand (~300+ lines). Either option is materially more
complex than the C++ one-liner.

UM's public API is C and is trivially callable from C++, so the
C++ choice only affects the protobuf layer.

The rest of the program uses C style — plain functions, no classes,
`extern "C"` on the `lbmmon` passthrough callback because
`lbmmon`'s function-pointer type is C-linked. Files:

- `lbmmon_json.cc` — main + passthrough callback
- `generated/*.pb.cc` / `generated/*.pb.h` — produced by
  `protoc --cpp_out` from the six `.proto` schema files. `bld.sh`
  fetches those from the UM online docs by default and caches
  them under `./proto/`; a user can override with `$UM_PROTO_DIR`
  (§9).

## 3. Packet type → protobuf message class map

Values from `<lbm/lbmmon.h>`. Message classes are the generated
C++ classes (`namespace lbmmon`) built from the `.proto` files
supplied at build time (§9).

| mType | Symbol                                 | Data-block message | Source .proto             |
|------:|----------------------------------------|--------------------|---------------------------|
| 0     | `LBMMON_PACKET_TYPE_SOURCE`            | `UMSMonMsg`        | `ums_mon.proto`           |
| 1     | `LBMMON_PACKET_TYPE_RECEIVER`          | `UMSMonMsg`        | `ums_mon.proto`           |
| 2     | `LBMMON_PACKET_TYPE_EVENT_QUEUE`       | `UMSMonMsg`        | `ums_mon.proto`           |
| 3     | `LBMMON_PACKET_TYPE_CONTEXT`           | `UMSMonMsg`        | `ums_mon.proto`           |
| 4     | `LBMMON_PACKET_TYPE_RECEIVER_TOPIC`    | `UMSMonMsg`        | `ums_mon.proto`           |
| 5     | `LBMMON_PACKET_TYPE_WILDCARD_RECEIVER` | `UMSMonMsg`        | `ums_mon.proto`           |
| 6     | `LBMMON_PACKET_TYPE_UMESTORE`          | `UMPMonMsg`        | `ump_mon.proto`           |
| 7     | `LBMMON_PACKET_TYPE_GATEWAY`           | `DROMonMsg`        | `dro_mon.proto`           |
| 8     | `LBMMON_PACKET_TYPE_UMDS`              | *(no schema — header-only)* | —                |
| 9     | `LBMMON_PACKET_TYPE_CONTROL_MESSAGE`   | `UMMonControlMsg`  | `um_mon_control.proto`    |
| 10    | `LBMMON_PACKET_TYPE_SRS`               | `SRSMonMsg`        | `srs_mon.proto`           |

Every top-level message except `UMMonControlMsg` has
`UMMonAttributes attributes = 1;` as its first field. Sender
metadata (IP, timestamp, ApplicationSourceID, process ID, context
instance, domain ID) lives inside the payload as that
`UMMonAttributes` submessage.

**Notes:**

- Type 9 (control message) *is* protobuf, decoded as
  `UMMonControlMsg`. It's rare to see one on the statistics
  topic — control messages are normally sent as immediate messages
  addressed to a monitored context — but the tool decodes it if
  it appears.
- Type 8 (UMDS) has no `.proto` schema in the UM source tree.
  `lbmmon_json` emits a header-only JSON record for these (packet
  type, `data_len`) with a note that no schema is available.

## 4. What `lbmmon` provides

Ground truth: `<lbm/lbmmon.h>` in the customer install
(`src/mon/lbm/lbmmon.h` in the UM source tree).

### 4.1 The receive controller

`lbmmon_rctl_t` is the receive-side controller. Creating one is a
single call:

```c
lbmmon_rctl_create(
    &monctl,
    format,           /* const lbmmon_format_func_t *  */
    format_options,   /* format module options string  */
    transport,        /* const lbmmon_transport_func_t*/
    transport_options,/* transport module options str */
    attr,             /* lbmmon_rctl_attr_t *          */
    client_data);
```

Internally `lbmmon_rctl_create` spawns a dedicated worker thread
that reads packets from the transport module, validates
`lbmmon_packet_hdr_t`, deserializes the attribute block, and fans
out to whichever callback the caller registered. `lbmmon_json` does
not need to (and should not) create an `lbm_context_t` or
`lbm_rcv_t` of its own.

### 4.2 Format module — `lbmmon_format_pb_module()`

Format modules define how the payload bytes are interpreted. Two
ship with UM:

- `lbmmon_format_csv_module()` — CSV serialization (legacy; used
  by old UM installs).
- `lbmmon_format_pb_module()` — protobuf serialization.

The `Format` argument passed to `lbmmon_rctl_create` is used for
packets whose module ID doesn't match either built-in — a slot for
custom format modules. `lbmmon_json` passes
`lbmmon_format_pb_module()` there, but note that this does **not**
mean CSV packets are dropped: the controller **always registers
both built-in format modules internally** (`lbmmonctl.c:663-664`,
`ctl->formats[LBMMON_FORMAT_CSV_MODULE_ID]` and
`ctl->formats[LBMMON_FORMAT_PB_MODULE_ID]` are populated
unconditionally). Dispatch keys off the *incoming packet's*
module ID (`lbmmonctl.c:832-838`), so a CSV packet reaches the
CSV deserializer even though we passed PB.

**Format options** are a semicolon-separated key=value string.
The same options string is handed to **both** built-in format
modules' `mInit` functions. The relevant key for `lbmmon_json`
is `passthrough`, with three possible values:

- `passthrough=off` — default; the deserializer unpacks the
  payload into a `lbm_*_stats_t` struct and the controller
  dispatches to the per-object-type callback registered for that
  packet type. Not what we want.
- `passthrough=on` — the deserializer returns
  `LBMMON_FORMAT_DESERIALIZE_PASSTHROUGH` **without** unpacking
  the payload; the controller dispatches to the passthrough
  callback (§4.4) with the raw payload bytes.
- `passthrough=convert` — for CSV packets, the CSV deserializer
  parses the payload into a `lbm_*_stats_t` struct **and then**
  the controller invokes the PB module's serializer to re-encode
  those stats as PB bytes, which are handed to the passthrough
  callback (`lbmmonctl.c:865-895` and equivalent branches per
  packet type). For PB packets, this behaves the same as
  `passthrough=on` — a PB→PB conversion is a no-op and the PB
  module's `mInit` treats `convert` as `on`
  (`lbmmonfmtpb.c:246-247`).

`lbmmon_json` uses **`passthrough=convert`**. Old UM installs (before
PB monitoring existed) still send CSV, and `passthrough=convert`
folds them into the normal delivery path transparently.

Coverage caveat: only the six object types the CSV format module
supported are convertible — SOURCE, RECEIVER, EVENT_QUEUE,
CONTEXT, RECEIVER_TOPIC, WILDCARD_RECEIVER. UMESTORE (Store),
GATEWAY (DRO), SRS, UMDS, and CONTROL_MESSAGE were PB-only from
introduction, so old CSV-emitting senders never produced them
anyway. In practice the six convertible types cover everything a
pre-PB UM would emit.

### 4.3 Transport module — `lbmmon_transport_lbm_module()`

Transport modules define how packets are received. UM ships:

- `lbmmon_transport_lbm_module()` — the packets travel on a UM
  topic, i.e. LBT-RM/LBT-RU/TCP. `lbmmon_json` needs this one.
- `lbmmon_transport_udp_module()` — raw UDP.
- `lbmmon_transport_lbmsnmp_module()` — SNMP-agent transport.

**Transport options** for the LBM module are a semicolon-separated
key=value string. Two keys matter:

- `config=FILE` — path to a UM configuration file, applied to the
  internal context/receiver the transport creates.
- `topic=NAME` — the statistics topic to subscribe to. Default
  (source: `lbmmontrlbm.c:137`, `DEFAULT_TOPIC`) is
  `/29west/statistics`, so we only need to set it when the user
  overrides via `-t`.

The LBM transport module creates its own `lbm_context_t` and
`lbm_rcv_t` behind the scenes; `lbmmon_json`'s only job is to keep
the process alive until interrupted.

### 4.4 The passthrough callback

`lbmmon_json` registers a **single** callback, the passthrough
callback:

```c
typedef void (*lbmmon_passthrough_statistics_cb)(
    const lbmmon_packet_hdr_t   *PacketHeader,
    lbmmon_packet_attributes_t  *Attributes,
    void                        *AttributeBlock,   /* unused */
    void                        *Statistics,       /* raw PB bytes */
    size_t                       Length,           /* Statistics length */
    void                        *ClientData);
```

Registration:

```c
lbmmon_passthrough_statistics_func_t pt = { passthrough_cb };
lbmmon_rctl_attr_setopt(attr, LBMMON_RCTL_PASSTHROUGH_CALLBACK,
                        &pt, sizeof(pt));
```

Key facts:

- `PacketHeader` fields are already converted to host byte order
  (see `lbmmonctl.c:802-805`). `PacketHeader->mType` selects the
  payload message class (§3).
- `Attributes` is already parsed by the format module. For PB, that
  means `mAddress` (network-order IPv4), `mTimestamp`,
  `mApplicationSourceID`, `mProcessID`, `mContextInstance`,
  `mDomainID`, and `mModuleID` are populated. `lbmmon_json` does not
  need these fields — the same identity information is present
  inside the payload's `UMMonAttributes` submessage — but they are
  available if a future feature wants them.
- `Statistics` points at the serialized data block only — no wire
  header, no attribute block. This is the byte range to pass to
  `ParseFromArray` on the C++ protobuf class.
- The callback runs on the `lbmmon` worker thread. It is
  serialized against itself — there is no concurrent-callback race
  to worry about.

## 5. Program structure

```
main()
 ├─ parse command line   (-c CONFIG, -t TOPIC, -h)
 ├─ lbmmon_rctl_attr_create(&attr)
 ├─ lbmmon_rctl_attr_setopt(attr, LBMMON_RCTL_PASSTHROUGH_CALLBACK,
 │                          &pt_func, sizeof(pt_func))
 ├─ format_options    = "passthrough=convert"           (std::string, local)
 ├─ transport_options = "config=FILE;topic=TOPIC"       (std::string, local;
 │                       only include keys the user set on the command line)
 ├─ lbmmon_rctl_create(&monctl,
 │      lbmmon_format_pb_module(),  format_options.c_str(),
 │      lbmmon_transport_lbm_module(), transport_options.c_str(),
 │      attr, NULL)
 ├─ lbmmon_rctl_attr_delete(attr)
 ├─ install SIGINT / SIGTERM handler → set running=0
 ├─ while (running) sleep(1)
 └─ lbmmon_rctl_destroy(monctl)
```

Local `std::string` storage for the option strings is safe: the
format module's `mInit` and the transport module's `mInitReceiver`
parse them (`strncpy` into private buffers) during
`lbmmon_rctl_create` and never re-read them afterwards.
`mApplyOptions` would re-read the buffer, but `lbmmon_json` never
calls it. The strings only need to outlive `lbmmon_rctl_create`.

Fatal errors in `main` (option parse, `lbmmon_rctl_*` failure) go
to `stderr` and terminate the program via `exit(1)`; `lbmmon_json`
treats these as fatal to the whole process and does not attempt
cleanup on the way out.

`passthrough_cb(hdr, attrs, attrblk, stats, len, clientd)`:

1. Switch on `hdr->mType`.
2. UMDS: emit header-only JSON record, return.
3. `CONTROL_MESSAGE`: `ParseFromArray` as `lbmmon::UMMonControlMsg`,
   `MessageToJsonString`, emit envelope with `data` only (no
   `attributes` field — the message has no `attributes`
   submessage). Return.
4. Otherwise `ParseFromArray` `stats[0..len)` as the class from
   §3's map (`UMSMonMsg` / `UMPMonMsg` / `DROMonMsg` /
   `SRSMonMsg`), extract `.attributes()` to `attrs_json`, clear it,
   serialize the remainder to `data_json`, emit the envelope.
5. Any `ParseFromArray` failure → emit a `warning` JSON line and
   return.
6. Any `hdr->mType` outside 0–10 → emit an
   `"unrecognized packet type"` warning and return. This branch is
   expected to be unreachable in practice — `lbmmon`'s own dispatch
   switch has no `default:` case, so packets with an unknown type
   never reach us — but it is kept as a cheap two-line safety net.

## 6. Command line

```
lbmmon_json [-c CONFIG] [-t TOPIC] [-h]

  -c CONFIG   UM configuration file (default: none — pure UM defaults)
  -t TOPIC    Statistics topic (default: /29west/statistics)
  -h          Print usage and exit
```

The `-c` / `-t` shorthand matches `lbmrcv` and other UM example
programs, so operators already know the convention.

## 7. JSON output shape

Every line is a self-contained JSON object terminated with `\n`,
written to `stdout`. Every line carries a millisecond-resolution
UTC timestamp.

### 7.1 Valid statistics packet

```json
{"ts":"2026-09-23T14:23:45.123Z","packet_type":"CONTEXT","attributes":{ ... },"data":{ ... }}
```

- `ts` — ISO 8601 UTC timestamp with milliseconds, e.g.
  `2026-09-23T14:23:45.123Z`.
- `packet_type` — symbolic name of `mType` (e.g. `"SOURCE"`,
  `"CONTEXT"`, `"UMESTORE"`).
- `attributes` — JSON form of the `UMMonAttributes` message.
- `data` — JSON form of the payload message.

`MessageToJsonString` options:

- `preserve_proto_field_names = true` — snake_case field names
  matching the `.proto` files.
- `add_whitespace = false` — one-line output.
- `always_print_primitive_fields = false` — zero-valued counter
  fields omitted.

Sender-identity fields (application source id, IPv4, process id,
context instance, domain id) live inside the payload's
`UMMonAttributes` submessage, which `lbmmon_json` renders into the
envelope's `attributes` field. There is no separate top-level
`source` field on the envelope — the passthrough callback does
not receive a transport-session string, and the identity is
already present under `attributes`.

### 7.2 UMDS packet (no schema)

```json
{"ts":"...","packet_type":"UMDS","note":"no protobuf schema for UMDS payload","data_len":128}
```

### 7.3 CONTROL_MESSAGE packet (no `attributes` submessage)

```json
{"ts":"...","packet_type":"CONTROL_MESSAGE","data":{ ... }}
```

### 7.4 Warning (parse error or unknown packet type)

```json
{"ts":"...","warning":"payload parse failed","reason":"UMSMonMsg","len":128}
```

Possible `warning` values:

- `"payload parse failed"` — data-block protobuf decode failed.
  `reason` names the class that was tried.
- `"unrecognized packet type"` — header `type` outside 0–10.
  Defensive; should be unreachable because `lbmmon` filters
  unknown types before invoking the callback.

Signature/framing errors on the wire are handled by `lbmmon`
itself: the library logs them via `lbm_log` (`Core-6033-12`) and
drops the packet. They never reach `lbmmon_json`'s callback, so
there is no envelope-level equivalent of a "malformed packet"
warning. Likewise, transport events (BOS/EOS/loss) on the
statistics topic are consumed inside the library and are not
delivered to the callback.

Downstream tooling can distinguish output categories cheaply by
grepping the first few tokens: `"packet_type":` for statistics,
`"warning":` for anomalies.

## 8. Build

The build system follows the model in
`~/GitHub/um_perf/`: a single `bld.sh`, and a checked-in
`lbm.sh.example` the user copies to `lbm.sh` and fills in with
their UM license and install path. `lbm.sh` is gitignored.

Repo layout:

```
lbmmon_json/
├─ CLAUDE.md            (maintainer notes for Claude)
├─ README.md            (user-facing)
├─ design.md            (this file)
├─ bld.sh               (shell script, single-pass build)
├─ lbm.sh.example       (user copies to lbm.sh, fills in)
├─ lbm.sh               (gitignored — license + $LBM [+ optional $UM_PROTO_DIR])
├─ lbmmon_json.cc          (main + passthrough callback)
├─ proto/               (default .proto cache, gitignored; §9)
│   └─ *.proto          (fetched from UM online docs on first build)
└─ generated/           (regenerated every build; gitignored)
    ├─ *.pb.cc
    └─ *.pb.h
```

`bld.sh` unconditionally:

1. Sources `lbm.sh` for `$LBM`, `$LBM_LICENSE_INFO`, and
   (optionally) `$UM_PROTO_DIR`.
2. If `$UM_PROTO_DIR` is set, uses it as-is. Otherwise defaults
   `$UM_PROTO_DIR` to `./proto/` and, for each of the six expected
   `.proto` files missing from that directory, fetches it from
   `https://ultramessaging.github.io/currdoc/doc/example/<name>.proto`
   with `curl` (falling back to `wget`). See §9 for the rationale.
3. Verifies the six expected `.proto` files are now present in
   `$UM_PROTO_DIR`; fails with a pointer to §9 if not.
4. `mkdir -p generated && rm -f generated/*.pb.h generated/*.pb.cc`
5. Runs `protoc --cpp_out=generated -I"$UM_PROTO_DIR" "$UM_PROTO_DIR"/*.proto`
   — requires the Google `protoc` binary on `$PATH` (§9).
6. Compiles `lbmmon_json.cc` and `generated/*.pb.cc` with `g++`,
   linking against `$LBM/lib/liblbm.*` and the system `libprotobuf`,
   producing `lbmmon_json`.

Link line (Linux, glibc-2.17-x86_64):

```
g++ -std=c++17 -Wall -g \
    -I$LBM/include -I$LBM/include/lbm -Igenerated \
    lbmmon_json.cc generated/*.pb.cc \
    -L$LBM/lib -llbm \
    -lprotobuf -lm -pthread -lrt \
    -o lbmmon_json
```

macOS branches on `uname` for the link flags (drop `-lrt`, use
`-lpthread`) as `um_perf/bld.sh` does.

`liblbm.so` already contains `lbmmon_rctl_*` and the transport /
format modules; there is no separate `-llbmmon` on the link line.

## 9. Prerequisites and `.proto` schemas

To **build** `lbmmon_json`:

- A customer-facing UM install (`$LBM` pointing at e.g.
  `$HOME/UMP_6.17.1/Linux-glibc-2.17-x86_64`). Confirmed to contain
  everything the build needs: `lbm.h`, `lbmmon.h`,
  `lbmmonfmtpb.h`, and `liblbm.so`.
- **`.proto` schema files** for the monitoring messages. `bld.sh`
  obtains them one of two ways (below).
- The Google Protocol Buffers **C++** toolchain, installed by the
  user:
  - `protoc` on `$PATH`
  - `libprotobuf` headers and shared library
  - Any recent 3.x release is fine; UM's Java jars use 3.21.12,
    but C++ compatibility is loose enough that stock distribution
    packages (e.g. `libprotobuf-dev` / `protobuf-compiler` on
    Ubuntu, `protobuf` from Homebrew on macOS) work.
- A C++17 compiler.
- For plan A (default): `curl` or `wget` on `$PATH`, and
  outbound HTTPS reachability to `ultramessaging.github.io` on
  the first build. Neither is required after the cache is
  populated.

To **run** `lbmmon_json`:

- `$LBM/lib` on `LD_LIBRARY_PATH` (or equivalent).
- Network reachability to the UM statistics topic (typically
  requires matching UM configuration to the monitored apps).

### 9.1 Where the `.proto` files come from

Both UM's `liblbm.so` and its `.proto` schemas ship with UM
releases, but in **different** packages: the wire-framing pieces
(`<lbm/lbmmon.h>`, `liblbm.so`) are in the binary install, while
the six monitoring `.proto` files ship with UM's **doc**
package. The `lbmmon_json` build accommodates both worlds via two
resolution modes:

**Plan A — auto-fetch from the UM online docs (default).**

If `$UM_PROTO_DIR` is unset, `bld.sh`:

1. Defaults `$UM_PROTO_DIR` to `./proto/` and `mkdir -p`s it.
2. For each of the six expected `.proto` files missing from
   `./proto/`, downloads
   `https://ultramessaging.github.io/currdoc/doc/example/<name>.proto`
   with `curl -fsSL` (or `wget -q` if `curl` is not present).
3. Uses the resulting directory as `$UM_PROTO_DIR`.

`./proto/` is gitignored. Subsequent builds hit the cache and
do not touch the network.

The `currdoc` path points at the schemas for the current UM
release. This is safe to use against older UM installs
because **UM's monitoring `.proto` files are maintained to be
backwards compatible** — fields are added, never removed or
renumbered — so a `lbmmon_json` built against the current
schemas correctly decodes packets emitted by any earlier
supported release.

**Plan B — user-supplied local directory (opt-in).**

If `$UM_PROTO_DIR` is set in `lbm.sh`, `bld.sh` uses it
verbatim and skips the fetch. This is the right mode for:

- **Offline builds.** A machine with no HTTPS reachability to
  `ultramessaging.github.io`.
- **Reproducible builds.** Pinning to a specific version
  snapshot (e.g. the schemas from a released UM doc package
  extracted into a versioned directory) so the same commit
  always rebuilds against the same schemas.

The user is responsible for populating `$UM_PROTO_DIR` with
the six files. Typical sources:

- The `.proto` files bundled with a UM doc package.
- An internal snapshot archive (e.g. one directory per UM
  release under a shared path).

Either way, `bld.sh` verifies the six expected files are
present in `$UM_PROTO_DIR` before invoking `protoc`; if any
is missing it errors out with the offending path.

### 9.2 The six files

| File                        | Contains                                   |
|-----------------------------|--------------------------------------------|
| `ums_mon.proto`             | `UMSMonMsg` — SOURCE, RECEIVER, EVENT_QUEUE, CONTEXT, RECEIVER_TOPIC, WILDCARD_RECEIVER |
| `ump_mon.proto`             | `UMPMonMsg` — UMESTORE (persistent Store)  |
| `dro_mon.proto`             | `DROMonMsg` — GATEWAY (DRO)                |
| `srs_mon.proto`             | `SRSMonMsg` — SRS                          |
| `um_mon_control.proto`      | `UMMonControlMsg` — CONTROL_MESSAGE        |
| `um_mon_attributes.proto`   | `UMMonAttributes` — imported by the others |

`ums_mon.proto`, `ump_mon.proto`, `dro_mon.proto`, and
`srs_mon.proto` each `import "um_mon_attributes.proto"`, so
all six are required regardless of which packet types the
user cares about — `protoc` refuses to compile any of the
top-level schemas without the attributes schema alongside.

There is no `.proto` for UMDS packets (`mType = 8`); `lbmmon_json`
handles those by emitting a header-only JSON record (§7.2).

## 10. Threading and lifecycle

- Single `lbmmon_rctl_t` receive controller. The library spawns one
  worker thread internally; `lbmmon_json` runs the passthrough
  callback on that thread and does no locking of its own.
- Callback returns quickly (target ≤ 1 ms for a typical stats
  packet). Monitoring intervals are seconds, not microseconds, so
  there is no queueing layer.
- `main` blocks on a signal-driven flag; on SIGINT/SIGTERM it
  clears the flag and falls through to `lbmmon_rctl_destroy`,
  which stops the worker thread and tears down the internal
  context/receiver.
- Fatal errors on the setup path (`lbmmon_rctl_attr_create`,
  `lbmmon_rctl_attr_setopt`, `lbmmon_rctl_create`) go to `stderr`
  and call `exit(1)` — the program treats these as fatal to the
  process, so no cleanup is attempted before exit.

## 11. Testing

`test/tst.sh` stands up a full single-host UM topology on loopback
— `lbmrd` (Mon TRD resolution), SRS (TRD1 resolution), DRO
(TRD1↔TRD2 bridge), persistent Store, `umesrc` publisher, and
`umercv` subscriber — with automatic monitoring enabled and
`lbmmon_json` in the role of the monitoring-data receiver.

`umercv` deliberately monitors in **CSV** while every other
component monitors in PB. This exercises `lbmmon`'s
`passthrough=convert` path: `lbmmon_json`'s callback receives the
CSV-origin packets as PB, indistinguishable from packets from the
PB senders. A clean run has zero `warning` lines — a nonzero
count would be a regression.

The finishing summary at the end of `tst.sh` reports:

- packet-type counts,
- up to five `warning` lines.

## 12. Out of scope

- **Sending** control messages back to monitored applications
  (SET_INTERVAL, SAMPLE, SNAP, etc.).
- Wildcard / PCRE topic matching.
- Any filtering — by ApplicationSourceID, by packet type, by
  field. Callers pipe to `jq` for that.
- Multi-context / event-queue architectures.
- Decoding the UMDS payload — no `.proto` schema exists. Header
  is still emitted.
- Retaining transport-event (BOS/EOS/loss) visibility. `lbmmon`
  consumes those internally and they do not reach the callback;
  reproducing them would require a second, redundant `lbm_rcv_t`
  on the statistics topic outside the `lbmmon` controller, which
  is more complexity than the diagnostic value warrants.
