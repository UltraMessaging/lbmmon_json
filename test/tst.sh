#!/bin/sh
# tst.sh - end-to-end test that exercises lbmmon_json against a
#          full UM topology (SRS + DRO + Store + publisher +
#          subscriber), all auto-monitoring to a Mon TRD.
#
# Modeled on ~/GitHub/mcs_demo/tst.sh, with two differences:
#   - The MCS + lbmmon.java processes are gone; lbmmon_json plays
#     the role of the monitoring-data receiver.
#   - Everything runs on a single interface (mcs_demo splits
#     production traffic onto .4 and monitoring onto .3;
#     impossible here).

set -u
cd "$(dirname "$0")"

# ---------- Environment ----------
if [ ! -f ../lbm.sh ]; then
  echo "tst.sh: ../lbm.sh not found. Set it up in the repo root." >&2
  exit 1
fi
. ../lbm.sh

if [ ! -x ../lbmmon_json ]; then
  echo "tst.sh: ../lbmmon_json not built. Run ../bld.sh first." >&2
  exit 1
fi

# ---------- Detect local network for config templates ----------
LOCAL_IP=$(hostname -I | awk '{print $1}')
if [ -z "$LOCAL_IP" ]; then
  echo "tst.sh: could not detect a local IPv4 address via 'hostname -I'." >&2
  exit 1
fi
LOCAL_CIDR="${LOCAL_IP%.*}.0/24"
echo "Using LOCAL_IP=$LOCAL_IP  LOCAL_CIDR=$LOCAL_CIDR"

for TMPL in um.xml lbmrd.xml srs.xml store.xml; do
  sed -e "s|@LOCAL_IP@|$LOCAL_IP|g" -e "s|@LOCAL_CIDR@|$LOCAL_CIDR|g" \
      "$TMPL.template" >"$TMPL"
done

# ---------- Clean previous run ----------
rm -rf cache state
rm -f  *.log *.pid *.jsonl *.err umercv
mkdir cache state

# ---------- Build enhanced umercv (adds -q for event queue) ----------
gcc -Wall -I. -I$LBM/include -I$LBM/include/lbm -L$LBM/lib \
    -o umercv verifymsg.c umercv.c -llbm -lm >umercv.build.log 2>&1
if [ "$?" -ne 0 ]; then
  echo "`date` umercv build failed, see umercv.build.log" >&2
  exit 1
fi

# ---------- Process management ----------
kill_pids()
{
  PIDS="${LBMRD_PID:-} ${MONJSON_PID:-} ${SRS_PID:-} ${DRO_PID:-} ${STORE_PID:-} ${UMERCV_PID:-} ${UMESRC_PID:-}"
  echo "`date` kill $PIDS"
  kill $PIDS 2>/dev/null
}
trap "kill_pids; exit 1" 1 2 3 15

# Wait up to 5 seconds for $1 to exist.
wait_pidfile()
{
  for I in 1 2 3 4 5; do
    if [ -f "$1" ]; then return 0; fi
    sleep 1
  done
  echo "`date` $1 did not appear" >&2
  return 1
}

# ---------- Start infrastructure ----------
# lbmrd - Mon TRD topic resolution.
lbmrd lbmrd.xml >lbmrd.log 2>&1 &
LBMRD_PID="$!"; echo "`date` LBMRD_PID=$LBMRD_PID"

# lbmmon_json - monitoring-data receiver, using the lbmmon library's
# PB passthrough API. Replaces MCS+lbmmon in mcs_demo.
LBM_XML_CONFIG_FILENAME=um.xml LBM_XML_CONFIG_APPNAME=lbmmon_json \
  ../lbmmon_json >lbmmon_json.jsonl 2>lbmmon_json.err &
MONJSON_PID="$!"; echo "`date` MONJSON_PID=$MONJSON_PID"

# SRS - TRD1 topic resolution.
SRS srs.xml >srs.log 2>&1 &
if ! wait_pidfile srs.pid; then kill_pids; exit 1; fi
SRS_PID="`cat srs.pid`"; echo "`date` SRS_PID=$SRS_PID"

# DRO - connects TRD1 <-> TRD2.
tnwgd dro.xml >dro.log 2>&1 &
if ! wait_pidfile dro.pid; then kill_pids; exit 1; fi
DRO_PID="`cat dro.pid`"; echo "`date` DRO_PID=$DRO_PID"
sleep 1

# Persistent Store.
umestored store.xml >store.log 2>&1 &
if ! wait_pidfile store.pid; then kill_pids; exit 1; fi
STORE_PID="`cat store.pid`"; echo "`date` STORE_PID=$STORE_PID"
sleep 3

# ---------- Workload ----------
# Publisher (TRD1, persistent).
LBM_XML_CONFIG_APPNAME=umesrc LBM_XML_CONFIG_FILENAME=um.xml \
  umesrc -d 1 -l 700 -M 30 -P 1000 -L 6 topic1 >umesrc.log 2>&1 &
UMESRC_PID="$!"; echo "`date` UMESRC_PID=$UMESRC_PID"

# Delay so the subscriber has to recover from the Store.
echo "`date` sleep 6"
sleep 6

# Subscriber (TRD2, persistent, event-queue mode for evq stats).
LBM_XML_CONFIG_APPNAME=umercv LBM_XML_CONFIG_FILENAME=um.xml \
  ./umercv -q -v -v topic1 >umercv.log 2>&1 &
UMERCV_PID="$!"; echo "`date` UMERCV_PID=$UMERCV_PID"

# Wait for the publisher to complete.
echo "`date` wait $UMESRC_PID"
wait $UMESRC_PID
unset UMESRC_PID

# Let the subscriber time out and monitoring run for another cycle.
echo "`date` sleep 36"
sleep 36

kill_pids

# Give lbmmon_json a moment to flush.
sleep 2

# ---------- Report ----------
FILE=lbmmon_json.jsonl
echo
echo "=== $FILE ==="
wc -l "$FILE" lbmmon_json.err 2>/dev/null

TOTAL=$(wc -l <"$FILE")
if [ "$TOTAL" -eq 0 ]; then
  echo "FAIL: $FILE has no output." >&2
  exit 1
fi

echo
echo "=== packet_type counts ==="
grep -oE '"packet_type":"[A-Z_]+"' "$FILE" \
  | sort | uniq -c | sort -rn

echo
echo "=== warnings ==="
grep '"warning":' "$FILE" | head -5 || true

echo
echo "Done. Full output in test/$FILE"
