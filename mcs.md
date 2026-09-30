# mcs.md — cross-check `lbmmon_json` output against MCS + JsonPrint

**Status:** interactive (Q&A at the end; folded back into the body
once decisions land).

## 1. Goal

Verify that `lbmmon_json`'s per-packet JSON output is
functionally-equivalent to the JSON emitted by UM's Monitoring
Collector Service (MCS) when it uses the `JsonPrint` plugin
from <https://github.com/UltraMessaging/mcs_json_print>.

Both consumers subscribe to the same statistics topic
(default `/29west/statistics`); the same monitoring packets
should reach both. If the two streams disagree on packet counts,
`packet_type` categorization, field names, or field values, that
is a signal `lbmmon_json` may be diverging from the reference
implementation. MCS + JsonPrint is treated as the reference
because MCS is a shipped, QA'd product and the `JsonPrint`
plugin is a thin serializer over UM's already-deserialized
Java protobuf objects.

## 2. Reference: `~/GitHub/mcs_demo/json_print`

The MCS + JsonPrint setup used as the template.

- **`mcs.xml`** — connector config. Selects the plugin with
  `<type>class:JsonPrint</type>` and points at
  `mcs.properties`.
- **`mcs.properties`** — the plugin's own config. Sets
  `outFilePath=tst.json` (the file JsonPrint writes to).
- **`tst.sh`** — starts MCS as an ordinary Java process,
  building a long classpath from `$L/MCS/lib/*.jar`, the
  plugin's `JsonPrint.jar`, and the `com.informatica.um.monitoring.UMMonitoringCollector`
  main class.
- **`um.xml`** — has an `<application name="mcs">` entry with a
  `29west_statistics_context` on the monitoring TRD, exactly
  like every other automatically-monitored process.

The version of MCS in `mcs_demo/json_print/tst.sh` targets UM
6.15; the local install here is 6.17.1, so the classpath jar
names change (see §7).

## 3. What is added to `lbmmon_json` for this comparison

The comparison lives *alongside* the existing end-to-end test in
`test/`, not as a separate directory. Concretely:

1. **A copy of `JsonPrint.jar`** — either committed to the repo
   (if licensing permits) or fetched by `test/tst.sh` on first
   run from a documented URL. Deferred until §8 Q1 is answered.
2. **`test/mcs.xml`** — the MCS connector config, identical
   structurally to `mcs_demo/json_print/mcs.xml` but with any
   path adjustments for 6.17.1.
3. **`test/mcs.properties`** — sets `outFilePath=mcs.jsonl` so
   the two output files sit side-by-side under `test/`.
4. **`test/um.xml.template` addition** — a new
   `<application name="mcs">` entry with a mon-only context,
   parallel to the `<application name="lbmmon_json">` entry
   (there is no such entry today; `lbmmon_json` runs *without*
   an app-name mon context because its only context is the one
   `lbmmon` opens internally — this needs verifying too, see
   §8 Q3).
5. **`test/tst.sh` additions** — a stanza that starts MCS in
   the background and adds `mcs.pid`/`mcs.log` to the
   kill/cleanup lists; a comparison stanza at the end that
   diffs `lbmmon_json.jsonl` against `mcs.jsonl` on a
   normalized view.

MCS should be started **before** the workload, and both
`lbmmon_json` and MCS should already be subscribing before the
first monitoring emission — otherwise each one drops the first
few packets independently and the comparison is noisy.

## 4. Comparison method

`lbmmon_json.jsonl` and `mcs.jsonl` are each a stream of
JSON-per-line records covering the same wire packets. They will
never be byte-identical (see §5) so the comparison is on a
normalized projection:

For each record:

- Identify the emitting object via a stable key drawn from the
  attributes submessage — application source ID + context
  instance + object type (source / receiver / …) + object
  instance where present.
- Reduce to the numeric statistic fields only (drop timestamp,
  attribute strings, envelope names).
- Group by key and by monitoring interval, and report:
  - packets present in one stream but not the other,
  - fields present in one record but not the corresponding one,
  - numeric fields that disagree by more than a small tolerance
    (a few statistics are cumulative counters that can drift by
    one interval between two receivers of the same source).

The tool that does this is a small `jq` or Python script under
`test/` — deferred until we agree on the normalization rules in
§8 Q4.

## 5. Expected differences (do not need reconciling)

- **Envelope shape.** `lbmmon_json`'s envelope is
  `{ts, packet_type, attributes, data}`; JsonPrint's envelope
  is different (top-level Unix-time timestamp per the
  `mcs_demo` README, and no explicit `packet_type` — the
  packet type is implicit in which submessage is populated).
  The comparison strips envelope keys and works on the
  attribute + data payload.
- **Timestamp format.** `lbmmon_json` emits ISO-8601 UTC in
  `ts`. JsonPrint emits Unix time. Both are host-clock
  arrival timestamps, not part of the wire payload.
- **Field naming.** `lbmmon_json` sets
  `preserve_proto_field_names=true` so field names come out
  snake_case matching the `.proto` files. JsonPrint's default
  is unknown — most likely also snake_case since it uses
  `protobuf-java-util`'s `JsonFormat`, but this needs
  confirming (§8 Q2).
- **Zero-valued fields.** `lbmmon_json` sets
  `always_print_primitive_fields=false` so proto3 defaults are
  omitted. JsonPrint's setting is unknown; if it prints zeros,
  the normalized comparison drops them on both sides.
- **CSV-format packets.** `lbmmon_json` runs `lbmmon` in
  `passthrough=convert` mode, so `umercv`'s CSV monitoring
  becomes PB before it reaches the callback and appears as
  ordinary `packet_type` records. MCS's own behavior with CSV
  senders needs confirming (§8 Q5) — if MCS drops or
  categorizes them differently, the CSV packets are excluded
  from the comparison.

## 6. Expected agreements (must reconcile if they diverge)

- Same set of `(application_source_id, context_instance,
  object_kind, object_instance)` keys per monitoring interval.
- Same numeric values on identically-named statistic fields
  from the same wire packet.
- Same handling of the `CONTROL_MESSAGE` packet type (rare on
  the statistics topic but decodable — both should either emit
  it or both skip it).
- Same handling of `UMDS` — `lbmmon_json` emits a header-only
  record with a `note`; MCS's behavior needs checking (§8 Q6).

## 7. UM 6.17.1 classpath adjustments

The `mcs_demo/json_print/tst.sh` classpath was written for UM
6.15 and references jar names that do not exist in 6.17.1.
Local install has:

| mcs_demo (6.15)              | lbmmon_json target (6.17.1)         |
|------------------------------|-------------------------------------|
| `UMS_6.15.jar`               | `UMS_6.17.1.jar`                    |
| `protobuf-java-4.0.0-rc-2`   | `protobuf-java-3.21.12.jar`         |
| `protobuf-java-util-4.0.0-rc-2` | `protobuf-java-util-3.21.12.jar` |
| `log4j-api-2.14.1.jar` + `log4j-core-2.14.1.jar` | `logback-classic-1.2.3.jar` + `logback-core-1.2.3.jar` + `slf4j-api-1.7.25.jar` |

The logging jars differ because MCS switched from log4j to
logback between 6.15 and 6.17.1. `JsonPrint.jar` itself is
version-independent per the plugin repo, but if the plugin
was compiled against a different `UMS_*.jar` there may be a
binary-compat surprise (§8 Q1 covers this).

## 8. Review questions

***Q1***: Where should `JsonPrint.jar` come from?
Options: (a) build from source in
<https://github.com/UltraMessaging/mcs_json_print> as part of
`bld.sh`; (b) check a prebuilt jar into this repo; (c) require
the user to drop `JsonPrint.jar` into `test/` before running,
matching how `mcs_demo/json_print/tst.sh` does it. Also: is the
plugin binary-compatible across UMS jar versions (6.15 → 6.17.1)
or does it need recompiling per install?

***Answer***: Pull from github to get the latest. It should be binary compatible. I should add that, to the degree that the lbmmon_json.cc output differs from JsonPrint, we should modify lbmmon_json.cc to match JsonPrint's output as much as practical.

***Q2***: Does the `JsonPrint` plugin use
`preserve_proto_field_names=true` and
`always_print_primitive_fields=false` — matching `lbmmon_json`
— or a different combination? If different, do we normalize
inside the comparison tool, or change `lbmmon_json` to align?

***Answer***: I think the answer to that is buried in the MCS source code. Please research.

***Q3***: `lbmmon_json` today runs with no
`LBM_XML_CONFIG_APPNAME` — the `lbmmon` library opens its own
context internally. If we want MCS and `lbmmon_json` to share
the same monitoring TRD config in `um.xml`, do we (a) add an
explicit `lbmmon_json` application entry and pass
`LBM_XML_CONFIG_APPNAME=lbmmon_json` (already done in `tst.sh`
as of the current test), or (b) rely on default resolution?
Current `tst.sh` already does (a); confirming it's the intended
mode.

***Answer***: If you look in ~/GitHub/mcs_demo/json_print *.sh you will see how it makes sure that the MCS's context is configured.

***Q4***: What normalization rules should the comparison tool
apply? Proposal: (i) strip envelope keys; (ii) round all
timestamps to the second; (iii) treat missing-vs-zero as equal;
(iv) treat records as matching iff `application_source_id +
context_instance + object_kind + object_instance + interval` all
match; (v) numeric fields must match exactly (no tolerance);
(vi) report the first N discrepancies rather than every one. Is
"no numeric tolerance" too strict — will interval-boundary
races between the two receivers cause routine one-off drift on
cumulative counters?

***Answer***: To the degree practical, modify lbmmon_json.cc to match JsonPrint, even if it means dropping information that we had previously considered a requirement, like millisecond-resolution time of day.

***Q5***: How does MCS handle CSV-format monitoring packets
(`umercv` in the current test)? If MCS also converts them to
PB internally, the comparison is straightforward. If MCS drops
them or categorizes them as a separate type, we exclude those
packets from the comparison. Worth checking against `mcs.log`
during a dry run before writing the comparison tool.

***Answer***: I believe the MCS converts. This might be embedded in the ~/GitHub/mcs_demo/json_print *.sh or *.xml files.

***Q6***: How does MCS handle `UMDS` packets (header-only, no
`.proto` schema in the UM source tree)? `lbmmon_json` emits a
header-only JSON record with a `note`. If MCS silently drops
them, we exclude UMDS from the comparison; if MCS emits
something schema-less, we compare that.

***Answer***: Ignore for now.

***Q7***: Is the goal a one-shot verification run, or an
ongoing regression check that runs every time `test/tst.sh`
is invoked? If ongoing, MCS becomes a permanent build/runtime
dependency of the test suite (Java + the MCS jars + the plugin
jar); if one-shot, we can be more cavalier about the setup.

***Answer***: Let's make MCS a perm addition to the test.
