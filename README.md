# Self-Hosted Media / DVR Stack on TrueNAS SCALE

A single, upgrade-survivable Docker Compose stack for a *arr-based media automation
suite, fronted by **one** reverse proxy with **single sign-on**, on an **isolated
internal network** so no application is directly reachable except through the gate.

This repo documents the whole pattern end to end: building it from scratch, *and*
migrating to it from individually-installed TrueNAS catalog apps. The compose file
keeps the same internal ports and volume layout the catalog apps use, so the two
approaches are interchangeable and you can move between them without reconfiguring
each application.

> **Placeholders.** Everything network-specific is generalized. Replace these with
> your own values throughout:
>
> | Placeholder            | Meaning                            | Example to substitute  |
> |------------------------|------------------------------------|------------------------|
> | `example.com`          | your domain                        | `media.yourdomain.net` |
> | `dvr.example.com`      | proxy hostname (subfolder apps)    | `dvr.yourdomain.net`   |
> | `10.0.0.2`             | TrueNAS web UI IP                  | your TrueNAS IP        |
> | `10.0.0.4`             | dedicated IP/alias the proxy binds | a free IP on your LAN  |
> | `10.0.0.3`             | local DNS server (Pi-hole, etc.)   | your DNS IP            |
> | `10.0.0.0/24`          | your LAN subnet                    | your subnet            |
> | `tank`                 | ZFS pool name                      | your pool              |
> | `/mnt/tank/...`        | dataset paths                      | your paths             |
> | `myuser` / `1000:1000` | unprivileged app user UID:GID      | your media user        |
> | `America/Los_Angeles`  | timezone                           | your TZ                |
> | `REPLACE_WITH_*`       | secrets (API keys, tokens)         | your values            |

---

## Table of contents

1. [Architecture](#architecture)
2. [Why one combined stack](#why-one-combined-stack)
3. [The port and volume compatibility contract](#the-port-and-volume-compatibility-contract)
4. [Prerequisites](#prerequisites)
5. [TrueNAS: datasets and a dedicated proxy IP](#truenas-datasets-and-a-dedicated-proxy-ip)
6. [DNS and TLS (Cloudflare or any provider)](#dns-and-tls)
7. [The reverse proxy and SSO gate](#the-reverse-proxy-and-sso-gate)
8. [Deploying the stack](#deploying-the-stack)
9. [Per-application configuration](#per-application-configuration)
10. [The subfolder vs subdomain decision](#subfolder-vs-subdomain)
11. [Custom formats and quality (Recyclarr)](#custom-formats-and-quality-recyclarr)
12. [Migrating from existing catalog apps](#migrating-from-existing-catalog-apps)
13. [Scripts reference](#scripts-reference)
14. [Gotchas and Landmines](#gotchas-and-landmines)
15. [Security notes](#security-notes)

---

## Architecture

```
                 Internet / LAN
                       |
            (DNS: *.example.com -> 10.0.0.4)
                       |
        +--------------v---------------+
        |  SWAG (nginx + Let's Encrypt)|   binds 10.0.0.4:443 / :80  (only published ports)
        |  wildcard cert *.example.com |
        +------+-----------------+-----+
               |                 |
     forward-auth (subrequest)   reverse proxy
               |                 |
        +------v------+    +-----v------------------------------------+
        |  Organizr   |    |  internal Docker network "medianet"      |
        |  (SSO gate) |    |  (bridge, IPv6-enabled, no host ports)   |
        +-------------+    |                                          |
                           |  sonarr radarr lidarr prowlarr sabnzbd   |
                           |  bazarr tautulli cleanuparr flaresolverr |
                           |  seerr requestrr recyclarr               |
                           +------------------------------------------+

   host-networked, outside the stack:  Plex (32400)
   out of scope here: any other standalone apps you run (e.g. a torrent client,
   transcoder, etc.) are not part of this guide
```

Key properties:

- **One ingress.** Only the proxy publishes host ports (`:443`/`:80` on a dedicated
  IP). Every application listens only on the internal network and is reachable by
  container name from the proxy and from sibling apps. Nothing else is exposed.
- **SSO at the door.** Organizr provides a forward-auth endpoint; the proxy calls it
  as a subrequest before serving any app. Per-app logins become redundant and are
  disabled, so one Organizr login gates everything.
- **Isolated backend.** Because apps have no published ports, the LAN cannot reach
  them directly. Access control collapses to a single point: the proxy + SSO.
- **Upgrade-survivable.** The internal network is declared inline in the compose
  (not as an external pre-created network), so it is recreated on every redeploy
  and the stack updates cleanly as one unit.

---

## Why one combined stack

Running each app as its own TrueNAS catalog app works, but every app then needs its
own ingress story, its own auth, and its own exposed port. Folding the suite into a
single custom Compose app gives you:

- one network boundary instead of N,
- one place to apply SSO,
- container-name service discovery between apps (no IPs to maintain),
- a single update/redeploy unit,
- and no per-app host ports to firewall.

The cost is that you manage one YAML file instead of clicking through catalog UIs.
This repo's compose file is the payoff: it is the entire suite in one reviewable place.

---

## The port and volume compatibility contract

**This is the design choice that makes moving between deployment methods painless, so
it is deliberate: the internal ports in this compose file are the exact ports the
TrueNAS catalog apps assign to each container.** Sonarr `30027`, Radarr `30025`,
Lidarr `30014`, Prowlarr `30050`, SABnzbd `30055`, and so on are not arbitrary - they
are what you get if you install these as individual TrueNAS apps. By reusing them:

- An app's stored configuration (its `config.xml` / `*.ini`, which records the app's
  own listening port and URL base) is **identical** whether the app runs as a TrueNAS
  catalog app or as a service in this stack.
- You can **move an app between the two methods with no configuration change** - take
  the catalog app down and bring it up here (or vice versa) pointed at the same
  config dataset on the same port, and it neither notices nor needs re-setup.

In other words, this stack is a drop-in alternative to the catalog apps, not a
parallel universe with different settings. Keeping the ports aligned is what lets you
treat "TrueNAS catalog app" and "this compose stack" as interchangeable.

- **Ports** match the catalog apps' container ports (above). This means an app's stored
  configuration works unchanged across the two deployment styles.
  unchanged whether the app runs as a catalog app or inside this stack.
- **Volumes** map the same host dataset to the same in-container path the catalog app
  used. So `/mnt/tank/app-volumes/<app>:/config` carries the identical configuration
  database across the two deployment styles.

The practical result: you can lift an app from a catalog deployment into this stack
(or back) by pointing the same dataset at the same container path on the same port,
and the app neither notices nor needs reconfiguration. Keep this contract intact if
you change ports - change them in both the app's own config and the proxy conf, or
not at all.

> Some images do **not** honor a custom internal port via environment variable and
> serve on their image default instead (notably Tautulli on `8181`, Seerr on `5055`).
> For those, the contract is "match the image default and point the proxy there"
> rather than forcing the catalog port. See [gotchas](#gotchas-and-landmines).

---

## Prerequisites

- TrueNAS SCALE (tested on 25.10.x) with the Apps service enabled.
- A domain you control, with DNS managed somewhere that supports API-based ACME
  DNS-01 challenges (Cloudflare shown here; others work with the matching SWAG plugin).
- A local DNS server (Pi-hole, AdGuard, router, or split-horizon) so internal clients
  resolve your proxy hostname to the proxy's LAN IP.
- A free IP on your LAN to dedicate to the proxy (so it does not collide with the
  TrueNAS web UI on `:443`).
- Basic familiarity with `docker`, ZFS datasets, and the *arr apps.

---

## TrueNAS: datasets and a dedicated proxy IP

### Datasets

Create datasets for application configs and for media. A workable layout:

```
tank/app-volumes/            parent for per-app config dirs
tank/app-volumes/sonarr
tank/app-volumes/radarr
tank/app-volumes/lidarr
tank/app-volumes/prowlarr
tank/app-volumes/sabnzbd
tank/app-volumes/bazarr
tank/app-volumes/tautulli
tank/app-volumes/seerr
tank/app-volumes/requestrr
tank/app-volumes/cleanuparr
tank/app-volumes/recyclarr
tank/app-volumes/swag
tank/app-volumes/organizr

tank/media/tvshows           library datasets (one per category as desired)
tank/media/movies
tank/media/music
tank/staging                 import staging (optional)
cache/downloads   download scratch (fast pool if available)
```

> **Cross-pool note.** If downloads land on one pool (e.g. an SSD `cache`) and the
> library is on another (`tank`), imports are a copy-and-delete, not a hardlink/atomic
> move. That is fine, but it means upgrades re-download and re-copy. Plan disk/IO
> accordingly. If you want hardlinks/instant moves, keep downloads and library on the
> same pool under a shared parent.

Ownership: pick one unprivileged user for everything that touches media and configs.
This repo assumes `1000:1000` (`myuser`). Set it on the datasets:

```bash
chown -R 1000:1000 /mnt/tank/app-volumes
chown -R 1000:1000 /mnt/tank/media
```

### Dedicated proxy IP

The TrueNAS web UI already uses `:443` on the host IP. To let the proxy also bind
`:443`, give it a **separate IP**. Two common approaches:

1. Pin the TrueNAS UI to its own IP and add a second IP/alias on the same interface
   for the proxy (`10.0.0.4`), then bind the proxy's published ports to that IP only
   (the compose does this: `10.0.0.4:443:443`).
2. Or run the proxy on a different host/VM entirely.

Add the alias on the interface (TrueNAS: Network > Interfaces > edit > add alias
`10.0.0.4/24`), and confirm with `ip a`.

---

## DNS and TLS

Two pieces: **DNS records** that map your hostnames to the proxy's IP, and a **TLS
certificate** that secures them.

### DNS records

Point each proxy hostname at the proxy IP. For **internal** clients these are local
DNS records; for **external/remote** access they are public records (or a tunnel/VPN -
see [security](#security-notes)).

Create one A record per hostname you use:

```
dvr.example.com        A    10.0.0.4     # all subfolder apps live under this one host
seerr.example.com      A    10.0.0.4     # one per app that needs its own subdomain
```

In Pi-hole: Settings > Local DNS Records (or Local DNS > DNS Records depending on
version), one entry per host. Confirm with `nslookup dvr.example.com 10.0.0.3`.

> Internal clients must use your local DNS for these names to resolve to the LAN IP.
> Devices on a public resolver will not see local records - relevant for phones and
> for sharing access with others.

### TLS: one wildcard certificate (DNS-01)

A single **wildcard certificate** `*.example.com`, obtained via the DNS-01 challenge,
secures every subdomain at once - so you never need a per-subdomain cert and can add
subdomains without touching TLS. SWAG handles issuance and renewal automatically.

For Cloudflare:

1. Create a **scoped API token** (not the Global key) with `Zone.Zone:Read` and
   `Zone.DNS:Edit` limited to your zone.
2. Put it in SWAG's `dns-conf/cloudflare.ini` as a single line - see
   [`examples/cloudflare.ini.example`](examples/cloudflare.ini.example). `chmod 600`.
3. Set SWAG's env: `VALIDATION=dns`, `DNSPLUGIN=cloudflare`, `URL=example.com`,
   `SUBDOMAINS=wildcard`, `CERTPROVIDER=letsencrypt`.

Other providers: SWAG ships DNS plugins for many registrars; swap `DNSPLUGIN` and the
matching `dns-conf/<provider>.ini`. The pattern is identical. The DNS-01 challenge
needs API access to create a temporary `_acme-challenge` TXT record during issuance.

---

## The reverse proxy and SSO gate

This stack uses **SWAG** (nginx + Certbot + the LinuxServer proxy-conf system) as the
proxy and **Organizr** as the SSO/forward-auth provider and dashboard.

### Organizr stays outside the stack (recommended)

Keep Organizr as a separate, host-reachable app rather than inside the combined stack.
Reason: it is your gate and dashboard; keeping it portable lets you move it (even to a
separate host reachable over a tunnel) without touching the media stack. The proxy
reaches it at a host address (e.g. `http://10.0.0.4:<organizr-port>`), and the
forward-auth subrequest in the proxy conf points there.

### How forward-auth works here

The proxy conf defines an internal auth endpoint and gates each app location on it:

```nginx
location ~ ^/auth-(\d+)$ {
    internal;
    proxy_pass http://10.0.0.4:<organizr-port>/api/v2/auth?group=$1;
    ...
}
location @organizr_login { return 302 https://$host/; }

location /sonarr {
    auth_request /auth-3;                 # require Organizr group <= 3
    error_page 401 = @organizr_login;     # bounce unauthenticated to login
    include /config/nginx/proxy.conf;
    proxy_pass http://sonarr:30027;       # by container name, internal
}
location /sonarr/api { auth_request off; proxy_pass http://sonarr:30027; }  # API bypasses SSO
```

- **Group numbers are privilege tiers** (lower = more privileged). Match each app's
  `auth-N` to the Organizr group allowed to use it.
- **`/<app>/api` bypasses the gate** so mobile apps and inter-app calls (which use API
  keys) keep working without an Organizr session.
- Apps are reached **by container name** because the proxy is on the same internal
  network as the apps.

See [`proxy-confs/media-apps.subfolder.conf`](proxy-confs/media-apps.subfolder.conf)
for the full, commented conf, and
[`proxy-confs/seerr.subdomain.conf`](proxy-confs/seerr.subdomain.conf) for the
subdomain pattern.

### Per-app auth on a new install

Because the proxy + Organizr is the access control, each app's own login is redundant
on the internal/proxied path. Here is what a fresh install of each does and what to
set so you end up with a single login (Organizr) instead of one per app:

- **The \*arr (Sonarr/Radarr/Lidarr/Prowlarr).** As of v4, authentication is
  mandatory: on first run each app *forces* you to create a username and password (you
  cannot skip it). That is fine - immediately afterward, go to
  Settings > General > Security and change **Authentication Required** to
  **"Disabled for Local Addresses"**, with method **Forms**. Because every request now
  arrives from the proxy on the internal network (a "local" address), the app serves it
  without prompting, while a request from anywhere unexpected still requires the login.
  Set each app's **URL Base** on the same screen (e.g. `/sonarr`) so it works under the
  proxy subfolder. A restart is needed for auth changes to take effect.
  - If "Disabled for Local Addresses" still prompts you through the proxy, the proxy is
    presenting a non-local source address to the app; either fix the forwarded address
    or use **Authentication Required: Disabled** (acceptable here precisely *because*
    Organizr + the isolated network are doing the access control - this is the
    documented "external auth in front" case).
- **SABnzbd.** A fresh install has **no web username/password set**, so there is no
  login prompt to begin with. Set `inet_exposure = 3` ("no login for the web
  interface", which keeps the API working - do not use a lower mode, those also
  restrict the API), set `url_base` to `/sabnzbd`, and add both your proxy hostname and
  the container name `sabnzbd` to `host_whitelist` (the *arr reach it by container
  name, and SABnzbd rejects hostnames not on the whitelist).

That is the whole story for a new install: create the forced *arr credential, relax it
to local-disabled, and leave SABnzbd loginless. Nothing to remove.

> **Already running these apps?** Converting an existing ("brownfield") setup has one
> extra wrinkle - an app that *already had a login* needs the stored credential
> actually cleared, not just a permissive mode set. That, plus a script to flip many
> *arr at once, is covered in
> [Migrating from existing catalog apps](#migrating-from-existing-catalog-apps).

---

## Deploying the stack

The combined stack is in [`compose/docker-compose.yaml`](compose/docker-compose.yaml).

1. **Edit the compose** for your environment: replace all placeholders (paths, TZ,
   PUID/PGID, the proxy bind IP, internal ports if you must change them).
2. **Set ownership** on every config dataset to your app user (see above). Several
   images run strictly non-root and crash on first start if `/config` is owned wrong.
3. **Stage the Cloudflare credential** at `tank/app-volumes/swag/<config>/dns-conf/cloudflare.ini`.
   Note SWAG nests its real config under a `config/` subdirectory - mount the level
   that contains `dns-conf/`, `nginx/`, etc.
4. **Deploy** as a TrueNAS Custom App: Apps > Discover Apps > Custom App > *Install
   via YAML*, paste the compose, name it, deploy. (Or `docker compose up -d` if you
   manage compose directly.)
5. **Verify** all services are `Up` and on the network:
   ```bash
   docker ps --format '{{.Names}}\t{{.Status}}'
   docker network inspect <project>_medianet -f '{{range .Containers}}{{.Name}} {{end}}'
   ```
   (The network name is prefixed by the compose project name TrueNAS assigns.)
6. **Install the proxy conf** into SWAG's `proxy-confs/` and reload:
   ```bash
   cp proxy-confs/media-apps.subfolder.conf <swag-config>/nginx/proxy-confs/
   docker exec swag nginx -t && docker exec swag nginx -s reload
   ```
7. **Watch SWAG's first boot** for cert issuance:
   ```bash
   docker logs -f swag
   ```
   You want it to issue/load the wildcard cert and start nginx, not error on the
   ACME challenge (which usually means a wrong/empty `cloudflare.ini`).

For update workflow and a debug variant that re-publishes host ports for
troubleshooting, see [scripts reference](#scripts-reference).

---

## Per-application configuration

After deploy, wire the apps to each other. **The critical rule: inter-app connections
use the container name *plus the app's URL base*** (the *arr serve their API under
their URL base, so omitting it causes confusing failures). Download clients are the
exception - SABnzbd's API is at the root, no base path.

| From                 | To                        | Address to use                                          |
|----------------------|---------------------------|---------------------------------------------------------|
| Prowlarr             | Sonarr/Radarr/Lidarr      | `http://sonarr:30027/sonarr` etc.                       |
| Sonarr/Radarr/Lidarr | SABnzbd (download client) | host `sabnzbd`, port `30055`, **no** base path          |
| Bazarr               | Sonarr/Radarr             | `sonarr` / `30027`, Base URL `/sonarr`                  |
| Seerr                | Sonarr/Radarr             | URL `http://sonarr:30027/sonarr`                        |
| Cleanuparr           | Sonarr/Radarr             | URL `http://sonarr:30027/sonarr`                        |
| Prowlarr             | FlareSolverr              | `http://flaresolverr:8191`                              |
| Tautulli             | Plex                      | Plex host IP `:32400` (host-networked, not on medianet) |

Notes:

- **API keys** are unchanged by the move; only host:port (+ base path) changes.
- **Use each app's Test button** - a green test confirms name resolution + port +
  base path at once.
- **External URL fields** (Cleanuparr, Seerr) are for clickable links in
  notifications - set them to the proxied address (`https://dvr.example.com/sonarr`)
  while the working/internal URL stays the container name.
- **Cleanuparr supports only torrent download clients**, not SABnzbd; on a
  Usenet-only setup it still adds value at the *arr layer (failed-import and
  junk-file cleanup). Set its `BASE_PATH` env to `/cleanuparr` to serve under that
  subfolder.
- **Bazarr** also needs a Base URL set in its own settings (`/bazarr`), at least one
  Languages **profile** created *and assigned* to content, and at least one
  subtitle **provider** enabled - the connections alone fetch nothing.

---

## Subfolder vs subdomain

Apps that support a configurable URL base can be served as a **subfolder**
(`dvr.example.com/sonarr`) and embedded in Organizr as iframes. Apps that do **not**
support a URL base (Seerr/Overseerr, Requestrr) need a **subdomain**
(`seerr.example.com`), each with a DNS record and a small SWAG subdomain conf - see
[`proxy-confs/seerr.subdomain.conf`](proxy-confs/seerr.subdomain.conf).

Also set Organizr tabs to **open in a new window** (not iframe) for:

- apps that frame-bust or loop inside an iframe (SABnzbd is the classic case), and
- any app still served over plain HTTP from a host port (mixed-content blocking
  blanks an http iframe inside an https page).

[`scripts/fix-organizr-tabs.py`](scripts/fix-organizr-tabs.py) classifies and updates
every tab (subfolder iframe / proxied-new-window / subdomain / external) in one pass.

---

## Custom formats and quality (Recyclarr)

[`scripts/recyclarr.yml`](scripts/recyclarr.yml) syncs TRaSH-Guide custom formats and
quality-profile scores into Sonarr and Radarr. This is optional - the stack works
without it - but it is a convenient way to manage quality preferences as code.

The included config sets up a **space-saving x265/HEVC preference**, which is a common
goal. It is deliberately conservative, and you should tune the scores to taste:

- **4K/UHD profiles:** x265 is preferred (positive score). At 2160p, HEVC is the
  native distribution codec, so preferring it saves space with no quality loss.
- **HD profiles (1080p/720p):** x265 is only *mildly* preferred, and the "x265 (HD)"
  format is scored negative to reject low-bitrate transcodes. This matters because
  most 1080p x265 releases are lossy transcodes of an x264 source - so a blanket "x265
  everywhere" preference at HD tends to pull in *worse* files. If you do not care about
  HD x265 at all, set those scores to 0; if you want maximum space savings and accept
  some quality risk, raise them. This is a preference, not a rule.

If you do not want any of this, skip Recyclarr entirely - the stack does not depend on
it. The TRaSH guides themselves are the place to go for a fuller quality setup beyond
this single space-saving example.

Fill in your API keys (replace `REPLACE_WITH_*`), set the `base_url` to your apps
(`http://sonarr:30027/sonarr`), then preview before applying:

```bash
recyclarr sync --preview     # shows every change, writes nothing
recyclarr sync               # applies
```

For x265 *upgrades of existing files* to actually fire, the profile's "Upgrade Until
Score" must be high enough that the x265 release out-scores what you already have, and
"Upgrades Allowed" must be on. Pace the upgrade backlog with
[`scripts/arr-upgrade-pacer.sh`](scripts/arr-upgrade-pacer.sh) to avoid burning through
indexer quotas with a catalog-wide search.

> Recyclarr's `quality_profiles:` key was renamed to `assign_scores_to:` in v8+. The
> included config uses the v8 name.

---

## Migrating from existing catalog apps

If you already run the apps as individual catalog apps, migrate without losing data by
relying on the [port/volume contract](#the-port-and-volume-compatibility-contract):
the same datasets carry the same configs into the stack.

Recommended phased approach (the safe path this repo was built from):

**Phase 1 - prove the proxy + SSO against the live catalog apps.** Before tearing
anything down, point a *host-IP* version of the proxy conf at the running apps' host
ports and validate that Organizr gating and each app load correctly. This de-risks the
whole cutover: if the proxy/auth model is wrong, you find out while rollback is trivial.

**Snapshot first.** Stop the apps for a consistent point-in-time, then snapshot:
```bash
for app in sonarr radarr lidarr prowlarr sabnzbd tautulli ...; do midclt call app.stop "$app"; done
# wait for STOPPED, then:
zfs snapshot -r tank/app-volumes@pre-migration
```

**Prep the \*arr - reduce them to no login.** This is the step that drops you from
"a login per app" to "just Organizr." On an *existing* app the relaxation differs from
a fresh install because the app already has a login configured:

- For the *arr, set **Authentication Required: "Disabled for Local Addresses"**, method
  **Forms**, and the **URL Base** (`/sonarr` etc.), then restart. The existing username
  and password stay on file but are no longer demanded for local (proxied) requests.
  [`scripts/prep-arr-apps.sh`](scripts/prep-arr-apps.sh) applies all three settings to
  many apps at once by editing each `config.xml` directly (it stops the app, edits,
  restarts) - far faster than clicking through each UI.
- For **SABnzbd**, this is the trap that cost the most time building this stack:
  setting a permissive `inet_exposure` is *not enough* if a web username/password is
  already stored, because **a stored credential is what enables the login prompt**. To
  get no login you must actually clear the stored web `username`/`password` (in the
  `[misc]` section of `sabnzbd.ini` - leave the `[servers]` Usenet credentials alone),
  in addition to setting `inet_exposure = 3`. Edit with the container stopped (SABnzbd
  rewrites its `.ini` on shutdown), then add the container name to `host_whitelist`.
  See [gotchas](#gotchas-and-landmines) for the full SABnzbd checklist.

**Dump and delete the catalog apps, preserving data:**
```bash
midclt call app.config "<app>" > backup/<app>.json        # record definitions
midclt call app.delete "<app>" '{"remove_ix_volumes": false}'   # keep the datasets
```
Delete the old proxy app **last** (it takes the site offline until the new one is up).

**Deploy the combined stack**, swap the proxy conf from host-IP to container-name
upstreams, repoint inter-app connectors (UI, with Test), and verify a real
download->import cycle end to end before retiring the snapshot.

**Rollback** at any point: stop/delete the new app (keep data),
`zfs rollback -r tank/app-volumes@pre-migration`, redeploy the originals.

---

## Scripts reference

All scripts live in [`scripts/`](scripts/). They read configuration from flags or a
config file and use placeholder defaults - edit for your environment. Each has a
header block with full usage.

| Script                  | Purpose                                                                                                                 | Edit before use                         |
|-------------------------|-------------------------------------------------------------------------------------------------------------------------|-----------------------------------------|
| `prep-arr-apps.sh`      | Set URL base + disabled-for-local auth in *arr `config.xml` (stops app, edits, restarts).                               | Dataset paths to your `app-volumes`.    |
| `fix-organizr-tabs.py`  | Classify and rewrite all Organizr tabs (subfolder/iframe, proxied-new-window, subdomain, external). Dry-run by default. | The classification maps + `--base-url`. |
| `make-debug-compose.py` | Derive a debug compose that re-publishes host ports for every app, for troubleshooting when the proxy is down.          | Input/output compose paths.             |
| `arr-upgrade-pacer.sh`  | Pace per-item upgrade searches across Sonarr/Radarr to work a backlog without exceeding indexer quotas. Resumable.      | Use a config file (see `examples/`).    |
| `recyclarr.yml`         | TRaSH custom-format + score sync config (x265 space-saving).                                                            | API keys + `base_url`.                  |
| `check-cert-expiry.sh`  | Monitor the proxy's TLS cert expiry (cron-friendly).                                                                    | Domain/host to check.                   |

Example configs are in [`examples/`](examples/). Copy, fill in, and keep the filled
copies out of version control (see `.gitignore`).

---

## Gotchas and Landmines

These cost real debugging time; they are the reason this repo exists.

- **Some images ignore a custom internal port.** Tautulli serves on `8181` and Seerr
  on `5055` regardless of a `PORT` env; point the proxy at the image default instead
  of forcing the catalog port. The *arr (LinuxServer/home-operations) and SABnzbd do
  honor their configured ports.
- **Non-root images crash on wrong ownership / a stray `user:` directive.** Tautulli,
  Seerr and similar must start as root and drop to `PUID/PGID` themselves - do **not**
  add a `user:` directive for them; just set `PUID/PGID` and `chown` the config dir.
- **SWAG nests its real config under `config/`.** Mount the directory that contains
  `dns-conf/` and `nginx/`, or it scaffolds empty defaults and the cert fails with a
  `9103` Cloudflare error.
- **SABnzbd is uniquely fiddly behind a proxy:**
  - "No login" requires **clearing the stored web username/password**, not just a
    permissive `inet_exposure` mode. A present credential is what enables the prompt.
  - `inet_exposure = 3` keeps the API working while removing the UI login; the very
    lowest modes also restrict the API and break the *arr connection.
  - On a dual-stack internal network it may be reached over IPv6; its `local_ranges`
    matching is IPv4-centric, so the UI hop can loop on login. Pin the proxy upstream
    to IPv4 (Docker resolver `ipv6=off` + variable `proxy_pass`); its outbound Usenet
    over IPv6 is a separate path and unaffected.
  - When connected by hostname, the container name must be in `host_whitelist`
    (IP connections bypass this check; hostname connections do not).
  - SABnzbd rewrites its `.ini` on shutdown - edit it with the container **stopped**,
    then verify the running value.
- **Inter-app calls to the *arr must include the URL base** (`/sonarr`); the API is
  served under the base. Forgetting it yields a "wrong URL base" or connection error.
- **Overseerr is now Seerr.** Overseerr/Jellyseerr merged into the maintained Seerr
  (`ghcr.io/seerr-team/seerr`); it auto-migrates existing appdata on first start, runs
  non-root, and needs `init: true`. Migrate by copying the old config dataset to a new
  one (cold backup) rather than in place.
- **Cross-pool imports are copy-and-delete, not hardlinks** - upgrades re-download and
  re-copy. Keep downloads and library on the same pool if you want instant moves.

---

## Security notes

- The whole model assumes the **proxy + SSO is the only ingress**. Publishing app host
  ports alongside it removes the isolation, so the stack keeps them internal. Use the
  debug compose only temporarily and tear it down.
- **Never commit secrets.** API keys, the Cloudflare token, and SWAG's `cloudflare.ini`
  stay out of the repo (`.gitignore` covers the common cases). The committed
  `recyclarr.yml` ships with `REPLACE_WITH_*` placeholders.
- **Local vs public DNS.** Publishing your proxy hostname publicly exposes the login
  page to the internet. For remote access without public exposure, prefer a mesh VPN
  (e.g. Tailscale) and keep the records local-only, scoping who can reach the proxy IP.
- **Use a scoped DNS API token**, never a global key, for ACME DNS-01.
- **Cookie/CAPTCHA/2FA flows are the user's** - automation should not complete logins,
  accept agreements, or solve human-verification on a user's behalf.

---

## License

Provided as-is, no warranty. Adapt freely. Attribution appreciated but not required.
