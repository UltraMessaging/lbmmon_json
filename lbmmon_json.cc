// lbmmon_json.cc - receive UM monitoring packets via the lbmmon
// library's PB passthrough API, print each as a JSON line.
//
// See design.md for the design.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <string>
#include <signal.h>
#include <unistd.h>
#include <sys/time.h>

#include <lbm/lbm.h>
#include <lbm/lbmmon.h>
#include <lbm/lbmmonfmtpb.h>
#include <lbm/lbmmontrlbm.h>

#include <google/protobuf/util/json_util.h>

#include "ums_mon.pb.h"
#include "ump_mon.pb.h"
#include "dro_mon.pb.h"
#include "srs_mon.pb.h"
#include "um_mon_attributes.pb.h"
#include "um_mon_control.pb.h"

using google::protobuf::util::JsonPrintOptions;
using google::protobuf::util::MessageToJsonString;

static const char *const kDefaultTopic = "/29west/statistics";

static volatile sig_atomic_t g_running = 1;
static JsonPrintOptions g_json_opts;

static void sig_handler(int) { g_running = 0; }

static std::string ms_utc_timestamp() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    struct tm t;
    gmtime_r(&tv.tv_sec, &t);
    char buf[64];
    snprintf(buf, sizeof(buf),
             "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
             t.tm_year + 1900, t.tm_mon + 1, t.tm_mday,
             t.tm_hour, t.tm_min, t.tm_sec,
             (int)(tv.tv_usec / 1000));
    return std::string(buf);
}

static const char *packet_type_name(int type) {
    switch (type) {
        case LBMMON_PACKET_TYPE_SOURCE:            return "SOURCE";
        case LBMMON_PACKET_TYPE_RECEIVER:          return "RECEIVER";
        case LBMMON_PACKET_TYPE_EVENT_QUEUE:       return "EVENT_QUEUE";
        case LBMMON_PACKET_TYPE_CONTEXT:           return "CONTEXT";
        case LBMMON_PACKET_TYPE_RECEIVER_TOPIC:    return "RECEIVER_TOPIC";
        case LBMMON_PACKET_TYPE_WILDCARD_RECEIVER: return "WILDCARD_RECEIVER";
        case LBMMON_PACKET_TYPE_UMESTORE:          return "UMESTORE";
        case LBMMON_PACKET_TYPE_GATEWAY:           return "GATEWAY";
        case LBMMON_PACKET_TYPE_UMDS:              return "UMDS";
        case LBMMON_PACKET_TYPE_CONTROL_MESSAGE:   return "CONTROL_MESSAGE";
        case LBMMON_PACKET_TYPE_SRS:               return "SRS";
        default:                                   return "UNKNOWN";
    }
}

// emit_warning() is invoked from the passthrough callback, which
// runs on the lbmmon worker thread. Calling printf/fflush from a
// context/worker-thread callback is a heavy-weight operation and
// is generally not recommended for production code; kept here for
// informational and educational purposes.
static void emit_warning(const char *warning, const char *reason, size_t len) {
    printf("{\"ts\":\"%s\",\"warning\":\"%s\"",
           ms_utc_timestamp().c_str(), warning);
    if (reason != nullptr) {
        printf(",\"reason\":\"%s\"", reason);
    }
    printf(",\"len\":%zu}\n", len);
    fflush(stdout);
}

template <typename Msg>
static bool decode_payload(const uint8_t *bytes, size_t len,
                           const char *type_label, size_t pkt_len,
                           std::string *attrs_json,
                           std::string *data_json) {
    Msg m;
    if (!m.ParseFromArray(bytes, (int)len)) {
        emit_warning("payload parse failed", type_label, pkt_len);
        return false;
    }
    attrs_json->clear();
    if (m.has_attributes()) {
        (void)MessageToJsonString(m.attributes(), attrs_json, g_json_opts);
    }
    m.clear_attributes();
    data_json->clear();
    (void)MessageToJsonString(m, data_json, g_json_opts);
    return true;
}

// This callback runs on the lbmmon worker thread (see design.md
// §12.4). It emits packets by calling printf/fflush directly.
// Doing heavy-weight I/O like printf from a context/worker-thread
// callback is generally not recommended for production code; the
// pattern is used here for informational and educational purposes.
// The individual printf/fflush call sites below are called out
// with matching short reminders.
extern "C" void passthrough_cb(const lbmmon_packet_hdr_t *hdr,
                               lbmmon_packet_attributes_t * /*attrs*/,
                               void * /*attr_block*/,
                               void *stats, size_t len,
                               void * /*clientd*/) {
    const uint8_t *bytes = (const uint8_t *)stats;
    const uint16_t type  = hdr->mType;

    if (type == LBMMON_PACKET_TYPE_UMDS) {
        // printf on worker-thread callback — see note above.
        printf("{\"ts\":\"%s\",\"packet_type\":\"UMDS\","
               "\"note\":\"no protobuf schema for UMDS payload\","
               "\"data_len\":%zu}\n",
               ms_utc_timestamp().c_str(), len);
        fflush(stdout);
        return;
    }

    if (type == LBMMON_PACKET_TYPE_CONTROL_MESSAGE) {
        lbmmon::UMMonControlMsg m;
        if (!m.ParseFromArray(bytes, (int)len)) {
            emit_warning("payload parse failed", "UMMonControlMsg", len);
            return;
        }
        std::string ctrl_json;
        (void)MessageToJsonString(m, &ctrl_json, g_json_opts);
        // printf on worker-thread callback — see note above.
        printf("{\"ts\":\"%s\",\"packet_type\":\"CONTROL_MESSAGE\","
               "\"data\":%s}\n",
               ms_utc_timestamp().c_str(), ctrl_json.c_str());
        fflush(stdout);
        return;
    }

    std::string attrs_json;
    std::string data_json;
    bool ok = false;
    switch (type) {
        case LBMMON_PACKET_TYPE_SOURCE:
        case LBMMON_PACKET_TYPE_RECEIVER:
        case LBMMON_PACKET_TYPE_EVENT_QUEUE:
        case LBMMON_PACKET_TYPE_CONTEXT:
        case LBMMON_PACKET_TYPE_RECEIVER_TOPIC:
        case LBMMON_PACKET_TYPE_WILDCARD_RECEIVER:
            ok = decode_payload<lbmmon::UMSMonMsg>(
                bytes, len, "UMSMonMsg", len, &attrs_json, &data_json);
            break;
        case LBMMON_PACKET_TYPE_UMESTORE:
            ok = decode_payload<lbmmon::UMPMonMsg>(
                bytes, len, "UMPMonMsg", len, &attrs_json, &data_json);
            break;
        case LBMMON_PACKET_TYPE_GATEWAY:
            ok = decode_payload<lbmmon::DROMonMsg>(
                bytes, len, "DROMonMsg", len, &attrs_json, &data_json);
            break;
        case LBMMON_PACKET_TYPE_SRS:
            ok = decode_payload<lbmmon::SRSMonMsg>(
                bytes, len, "SRSMonMsg", len, &attrs_json, &data_json);
            break;
        default: {
            char reason[64];
            snprintf(reason, sizeof(reason), "type %u", (unsigned)type);
            emit_warning("unrecognized packet type", reason, len);
            return;
        }
    }
    if (!ok) return;

    if (attrs_json.empty()) attrs_json = "{}";

    // printf on worker-thread callback — see note above.
    printf("{\"ts\":\"%s\",\"packet_type\":\"%s\","
           "\"attributes\":%s,\"data\":%s}\n",
           ms_utc_timestamp().c_str(),
           packet_type_name(type),
           attrs_json.c_str(),
           data_json.c_str());
    fflush(stdout);
}

static void usage(FILE *out) {
    fprintf(out,
            "Usage: lbmmon_json [-c CONFIG] [-t TOPIC] [-h]\n"
            "\n"
            "  -c CONFIG   UM configuration file (default: none)\n"
            "  -t TOPIC    Statistics topic (default: %s)\n"
            "  -h          Print this help and exit\n",
            kDefaultTopic);
}

int main(int argc, char **argv) {
    const char *config_file = nullptr;
    const char *topic_name  = nullptr;

    int opt;
    while ((opt = getopt(argc, argv, "c:t:h")) != -1) {
        switch (opt) {
            case 'c': config_file = optarg;     break;
            case 't': topic_name  = optarg;     break;
            case 'h': usage(stdout);            return 0;
            default:  usage(stderr);            exit(1);
        }
    }

    g_json_opts.add_whitespace = false;
    g_json_opts.preserve_proto_field_names = true;

    lbmmon_rctl_attr_t *attr = nullptr;
    if (lbmmon_rctl_attr_create(&attr) != 0) {
        fprintf(stderr, "lbmmon_rctl_attr_create: %s\n", lbmmon_errmsg());
        exit(1);
    }
    lbmmon_passthrough_statistics_func_t pt_func;
    pt_func.cbfunc = passthrough_cb;
    if (lbmmon_rctl_attr_setopt(attr, LBMMON_RCTL_PASSTHROUGH_CALLBACK,
                                &pt_func, sizeof(pt_func)) != 0) {
        fprintf(stderr, "lbmmon_rctl_attr_setopt(PASSTHROUGH): %s\n",
                lbmmon_errmsg());
        exit(1);
    }

    std::string format_options = "passthrough=convert";

    std::string transport_options;
    if (config_file != nullptr) {
        transport_options += "config=";
        transport_options += config_file;
    }
    if (topic_name != nullptr) {
        if (!transport_options.empty()) transport_options += ";";
        transport_options += "topic=";
        transport_options += topic_name;
    }

    lbmmon_rctl_t *monctl = nullptr;
    if (lbmmon_rctl_create(&monctl,
                           lbmmon_format_pb_module(),
                           format_options.c_str(),
                           lbmmon_transport_lbm_module(),
                           transport_options.c_str(),
                           attr, nullptr) != 0) {
        fprintf(stderr, "lbmmon_rctl_create: %s\n", lbmmon_errmsg());
        exit(1);
    }
    lbmmon_rctl_attr_delete(attr);

    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);

    while (g_running) {
        sleep(1);
    }

    lbmmon_rctl_destroy(monctl);

    google::protobuf::ShutdownProtobufLibrary();
    return 0;
}
