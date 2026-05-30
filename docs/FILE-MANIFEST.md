# File manifest

What each file is, and what you must change before using it.

## compose/
- **docker-compose.yaml** - the entire 13-service stack. Change: all `/mnt/tank/...`
  paths, `TZ`, `PUID/PGID`, the proxy bind IP `10.0.0.4`, and (only if you must)
  internal ports. Deploy via TrueNAS Custom App "Install via YAML" or `docker compose`.

## proxy-confs/
- **media-apps.subfolder.conf** - SWAG conf for the subfolder apps with Organizr
  forward-auth. Change: the Organizr address in the `auth-N` block, the `auth-N`
  group numbers to match your Organizr groups, and any ports you changed. Install to
  `<swag-config>/nginx/proxy-confs/`.
- **seerr.subdomain.conf** - SWAG conf template for a subdomain app (Seerr). Change:
  `server_name` to your subdomain, upstream container/port. Copy per subdomain app.

## scripts/
- **prep-arr-apps.sh** - sets URL base + disabled-for-local auth in *arr config.xml.
- **fix-organizr-tabs.py** - reconciles Organizr tabs to the proxied topology.
- **make-debug-compose.py** - derives a host-port-publishing debug compose.
- **arr-upgrade-pacer.sh** - paces upgrade searches within indexer quotas (resumable).
- **recyclarr.yml** - TRaSH custom-format/score sync (x265 space-saving).
- **check-cert-expiry.sh** - TLS expiry monitor (cron).

## examples/
- **arr-upgrade-pacer.conf.example** - copy to `.conf`, fill URLs/paths.
- **secrets.env.example** - reference values (TZ, PUID/PGID, domain).
- **cloudflare.ini.example** - SWAG DNS-01 credential format (scoped token).

Copy any `*.example` to its real name and keep the filled copy out of git.
