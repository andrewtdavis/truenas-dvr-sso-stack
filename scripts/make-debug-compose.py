#!/usr/bin/env python3
#
# Synopsis:
#   Derive a debug docker-compose from the locked compose by adding direct
#   host-port publishes to each app, for troubleshooting and migration fallback.
#
# Description:
#   The locked compose publishes ports only on the proxy; every other service is
#   reachable solely over the internal network. This tool reads that file and
#   writes a parallel debug file that additionally binds each app's web port to
#   a host address, so the UIs can be reached directly if the proxy layer itself
#   is being debugged. The locked file remains the single source of truth; the
#   debug file is regenerated from it, so the two cannot drift. Deploy whichever
#   is needed; do not run both against the same project name.
#
#   Services without a web port (for example recyclarr) are left unchanged, as
#   is the proxy, which already publishes.
#
# Parameters:
#   --in PATH       Locked compose to read. Default below.
#   --out PATH      Debug compose to write. Default below.
#   --bind-ip ADDR  Host address to bind the debug ports to. Default below.
#   --debug         Verbose tracing to stderr.
#
# Examples:
#   ./make-debug-compose.py
#   ./make-debug-compose.py --bind-ip 10.0.0.2 --out /tmp/dvr-debug.yaml
#

import argparse
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required (pip install pyyaml --break-system-packages).", file=sys.stderr)
    sys.exit(3)

DEFAULT_INPUT_PATH = "/mnt/tank/scripts/dvr-stack/docker-compose.yaml"
DEFAULT_OUTPUT_PATH = "/mnt/tank/scripts/dvr-stack/docker-compose.debug.yaml"
DEFAULT_BIND_IP = "10.0.0.4"

# Service name to web port to publish in the debug variant.
SERVICE_PORT_MAP = {
    "sonarr": 30027,
    "radarr": 30025,
    "lidarr": 30014,
    "prowlarr": 30050,
    "sabnzbd": 30055,
    "tautulli": 8181,
    "seerr": 5055,
    "requestrr": 4545,
    "bazarr": 6767,
    "cleanuparr": 11011,
    "flaresolverr": 8191,
}


def main():
    arg_parser = argparse.ArgumentParser(add_help=True)
    arg_parser.add_argument("--in", dest="input_path", default=DEFAULT_INPUT_PATH)
    arg_parser.add_argument("--out", dest="output_path", default=DEFAULT_OUTPUT_PATH)
    arg_parser.add_argument("--bind-ip", dest="bind_ip", default=DEFAULT_BIND_IP)
    arg_parser.add_argument("--debug", dest="debug_on", action="store_true")
    parsed_args = arg_parser.parse_args()

    with open(parsed_args.input_path, encoding="utf-8") as input_handle:
        compose_doc = yaml.safe_load(input_handle)

    services_block = compose_doc.get("services", {})
    added_count = 0
    for service_name, service_port in SERVICE_PORT_MAP.items():
        service_def = services_block.get(service_name)
        if service_def is None:
            if parsed_args.debug_on:
                print("DEBUG: %s not present, skipping" % service_name, file=sys.stderr)
            continue
        if "ports" in service_def:
            if parsed_args.debug_on:
                print("DEBUG: %s already publishes, leaving as-is" % service_name, file=sys.stderr)
            continue
        service_def["ports"] = ["%s:%d:%d" % (parsed_args.bind_ip, service_port, service_port)]
        added_count += 1

    header_text = ("# GENERATED debug variant - do not edit by hand; regenerate from the\n"
                   "# locked compose. Publishes app web ports on %s for direct access when\n"
                   "# the proxy layer is being debugged. Deploy the locked file for normal use.\n"
                   % parsed_args.bind_ip)
    with open(parsed_args.output_path, "w", encoding="utf-8") as output_handle:
        output_handle.write(header_text)
        yaml.safe_dump(compose_doc, output_handle, default_flow_style=False, sort_keys=False)

    print("# wrote %s (added host ports to %d services)" % (parsed_args.output_path, added_count),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
