# lbmmon_json

A small standalone program that receives Ultra Messaging (UM)
monitoring data messages, decodes them from protobuf, and prints
one JSON object per message to `stdout`.

**Current state:** initial code landed (`lbmmon_json.cc`, `bld.sh`).
See `design.md` for the design document.

## What this program is

- Uses the `lbmmon` library's receive controller in PB passthrough
  mode. `lbmmon` owns the UM context, the receiver on the
  statistics topic (default `/29west/statistics`), the wire-header
  validation, and the attribute-block deserialization.
- Registers a single passthrough callback. For each packet the
  library delivers, dispatches on the packet-header `mType` to the
  correct top-level protobuf message class (`UMSMonMsg`,
  `UMPMonMsg`, `DROMonMsg`, `SRSMonMsg`, or `UMMonControlMsg`),
  parses the raw payload bytes, and converts the decoded message
  to JSON with `google::protobuf::util::MessageToJsonString`.
- Emits one JSON line per packet to `stdout`.
- Uses `passthrough=convert` on the PB format module, so
  CSV-format monitoring packets from older UM installs are
  transparently converted to PB by `lbmmon` and reach the callback
  as ordinary `packet_type` records.
- Does **not** register any of `lbmmon`'s per-object-type
  callbacks — with `passthrough=convert` they never fire.

Written in **C++** because the protobuf → JSON conversion is a
one-line call in Google's C++ protobuf library; the `protobuf-c`
binding UM uses internally does not have that function. UM's C API
is called from C++ directly.

## Where the UM source lives

`lbmmon_json` needs UM public headers (`lbm.h`) at build time and
consults UM source paths at design/review time. The UM source
tree lives wherever `$LBM_REPO` points — typically a UM release
checkout, or (for internal maintainers with access) a Perforce
workspace of the `29West/lbm` tree. If neither is available,
the design and review references below can be read against any
UM source snapshot with the same layout.

Relevant subtrees inside that workspace:

- `src/mon/` — the `lbmmon` library. `lbmmon_json` links against
  `liblbm.so` (which contains `lbmmon`) at runtime; this tree is
  the ground-truth reference for the receive controller, format
  modules, and passthrough callback semantics. Key files:
  `src/mon/lbm/lbmmon.h` (public API used by `lbmmon_json`:
  `lbmmon_rctl_*`, `lbmmon_format_pb_module`,
  `lbmmon_transport_lbm_module`, `LBMMON_PACKET_TYPE_*`),
  `src/mon/lbmmonctl.c` (controller dispatch, especially
  `passthrough=on`/`convert` handling), and
  `src/mon/lbmmonfmtpb.c` (PB format module — how `mInit` treats
  the `passthrough` option, and the CSV→PB re-serialization path
  invoked by `passthrough=convert`).
- `src/monproto/` — the `.proto` definitions
  (`ums_mon.proto`, `ump_mon.proto`, `dro_mon.proto`,
  `srs_mon.proto`, `um_mon_attributes.proto`,
  `um_mon_control.proto`). These are the schemas `lbmmon_json` needs
  compiled to C++ via `protoc --cpp_out`.

Whichever UM source tree is at hand should be reachable via
`$LBM_REPO` (or an equivalent env var / symlink) so future
maintenance can find the same references without hardcoding
paths.

## When maintaining this tool: verify the `.proto` file list

The build and dispatch code both assume UM's monitoring layer
publishes exactly the six `.proto` files listed below. Adding or
removing one is unlikely but possible — before any non-trivial
maintenance pass, fetch the UM example index page and compare its
`.proto` list against the code:

```
curl -fsSL https://ultramessaging.github.io/currdoc/doc/example/index.html \
  | grep -oE 'href="\.\./example/[^"]*\.proto"' \
  | sed -E 's|.*/||; s|"$||' | sort -u
```

The index page renders each example under an `<h2>Example
NAME.proto</h2>` anchor with a `<p>Source code: <a
href="../example/NAME.proto">NAME.proto</a></p>` link, so the
grep above pulls just the bare filenames. If the current list
diverges from what this tool bakes in, treat that as a signal to
update the tool, not to work around it.

**Currently expected files (six):**

- `dro_mon.proto`
- `srs_mon.proto`
- `um_mon_attributes.proto` — imported by the others; no
  top-level statistics message of its own.
- `um_mon_control.proto`
- `ump_mon.proto`
- `ums_mon.proto`

**If the index shows a new file, update these places:**

1. **`bld.sh`** — extend the `PROTO_FILES` variable so the
   auto-fetch loop pulls the new file. Also runs through
   `protoc`.
2. **`lbmmon_json.cc`** —
   - Add `#include "newname.pb.h"` alongside the existing
     `*_mon.pb.h` includes.
   - If the new schema defines a new **top-level** statistics
     message (i.e. UM has also added a new `mType` value and a
     matching `LBMMON_PACKET_TYPE_*` symbol in
     `<lbm/lbmmon.h>`), add:
     - a case in `packet_type_name()` mapping the new symbol
       to its display string,
     - a case in `passthrough_cb`'s switch that dispatches to
       the new message class — follow the `UMSMonMsg` /
       `UMPMonMsg` / ... pattern via `decode_payload<>`, or the
       `UMMonControlMsg` pattern if the new schema has no
       `attributes` submessage.
   - If the new file is a **support** schema like
     `um_mon_attributes.proto` (imported by the others but
     without a top-level statistics message), no dispatch
     changes are needed — but `bld.sh` still has to fetch it so
     `protoc` can compile the schemas that import it.
3. **`design.md`** — update §3 (packet-type → message-class
   map) and §9.2 (six-file table).
4. **`README.md`** — update the "six files fetched are..."
   sentence in the `.proto` prerequisite.

Note on version alignment: if UM introduces a new
`LBMMON_PACKET_TYPE_*`, the new symbol only exists in the
customer install that ships that release's `<lbm/lbmmon.h>`.
Local builds against an older `$LBM` will fail to compile the
new case. That mismatch is the maintainer's cue to require a UM
install at least as new as the schema.

Files disappearing from the list is even more unlikely — UM
keeps monitoring `.proto` files backwards compatible (see §9.1
of `design.md`) — but the same review checklist applies in
reverse.

## Skills to load when working on this repo

When starting work in this directory, load the **`um-ref`** skill —
it carries the UM domain knowledge (contexts, receivers, transports,
monitoring specifics) needed to read the design and reason about
implementation. The parent UM workspace's own `CLAUDE.md` (when
the maintainer is working from one) also requires it for any
work in that tree.

## Doc conventions in this repo

Design documents in this repo are **formal**: the body reflects
only the current state of the design. When a doc is being actively
reviewed, follow the maintainer's global preference — append
review questions / findings at the bottom with empty
`***Answer***` lines, then fold the answers back into the body
and strip the Q&A trail once the review is settled.

## Git permissions

Claude has **full permission to `git add`, `git commit`, and
`git push`** in this repository when appropriate — for example
after applying an agreed-upon edit, after folding Q&A answers into
the design, or after landing a code change the maintainer has
approved.

- Follow the attribution-line guidance the harness gives at commit
  time (currently: `Co-Authored-By: Claude Opus 4.7 (1M context)
  <noreply@anthropic.com>` on commits).
- Do not `--amend` or force-push published history without an
  explicit ask.
- Do not skip hooks (`--no-verify`) or bypass signing.
- The rest of the standard git-safety protocol still applies
  (never rewrite config, never destructive ops without a clear
  request).

The remote is `origin` (run `git remote -v` for the current
URL). The default branch is `master`.
