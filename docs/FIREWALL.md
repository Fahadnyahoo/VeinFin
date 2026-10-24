# Host and Docker firewall

VeinFin uses `iptables-nft` with dedicated `VEINFIN-HOST-IN` and `VEINFIN-DOCKER` chains. It inserts one first-position jump from `INPUT` and one from Docker's `DOCKER-USER` chain for both IPv4 and IPv6. Docker continues to own all `DOCKER*` chains; VeinFin never flushes, replaces, or deletes them.

Conflict inspection recognizes only the standard `filter`, `nat`, and `raw` nft compatibility tables for IPv4 and IPv6. Docker's iptables backend may create a `raw` table for bridge and loopback-publication isolation; independently managed nftables tables are still rejected for manual review.

The firewall must be established before any VeinFin application container starts. The script refuses to apply when the active SSH peer is outside the configured management allowlist, the default interface is ambiguous or unsafe, non-Docker firewall policy already exists, another firewall manager is active/enabled, Docker's IPv4 or IPv6 `DOCKER-USER` chain is missing, the Docker TCP API is listening, or any container already exists.

## Commands

```sh
scripts/host/configure-firewall.sh --help
scripts/host/configure-firewall.sh --check --config /path/to/private-firewall.conf
sudo scripts/host/configure-firewall.sh --apply --config /path/to/private-firewall.conf
sudo scripts/host/configure-firewall.sh --update-public-https --config /path/to/private-firewall.conf
sudo /usr/local/sbin/veinfin-firewall --verify
sudo /usr/local/sbin/veinfin-firewall --remove
```

`--check` is read-only. It needs root access to inspect packet-filter state and uses passwordless `sudo -n` when invoked as an ordinary user. `--apply` installs and applies policy but leaves a five-minute automatic rollback armed. Open a second SSH connection from the current management client and run `--verify`; rollback is cancelled only if all checks pass. `--remove` disables persistence and removes only marked VeinFin files, jumps, and chains.

Applying the same configuration repeatedly is supported. It updates only VeinFin-owned chains and preserves Docker and unrelated base-chain policies.

After containers exist, the initial `--apply` path remains prohibited. HTTPS deployment instead uses `--update-public-https`, which accepts only `ENABLE_PUBLIC_HTTPS=false` to `true` while requiring every CIDR, SSH port, management flag, and management-port list to match the installed policy exactly. It snapshots rules and persistence files and arms the same five-minute rollback. A separate SSH session must run `--verify` before the timer expires.

## Private configuration

Create the input only on the target host, with mode `0600`, and never add it to Git. Required values are:

```text
MANAGEMENT_ALLOWED_CIDRS=<comma-separated IPv4 CIDRs>
PROTECTED_LAN_CIDRS=<comma-separated IPv4 CIDRs>
SSH_PORT=<host SSH port>
ENABLE_PUBLIC_HTTPS=false
ENABLE_MANAGEMENT_PORTS=false
```

Optional `MANAGEMENT_ALLOWED_IPV6_CIDRS` defaults empty. With no IPv6 management source, new SSH over IPv6 is blocked. Optional `MANAGEMENT_TCP_PORTS` defaults to the private ports declared by the repository; set it explicitly if those ports are customized. Only `true` and `false` are accepted for exposure flags.

On apply, the validated values are atomically installed at `/etc/veinfin/firewall.conf`, owned by root with mode `0600`. The repository contains no deployment CIDRs or target addresses.

## Host-input policy

In order, each address family permits:

1. Loopback traffic.
2. `ESTABLISHED,RELATED` traffic, preserving the current SSH session and replies to outbound connections.
3. ICMP for IPv4 and ICMPv6 for IPv6, including required path-MTU and neighbor-discovery behavior.
4. DHCP client replies (UDP 67 to 68 for IPv4 and UDP 547 to 546 for IPv6).
5. New TCP SSH connections only from the configured same-family management CIDRs.

All other unsolicited host input is dropped. IPv6 stays enabled; it receives an equivalent fail-closed policy rather than being ignored or disabled.

## Docker-forwarding policy

The `VEINFIN-DOCKER` chain is first in `DOCKER-USER`, so it evaluates forwarded packets before Docker's accept rules:

- `ESTABLISHED,RELATED` forwarding is accepted.
- Traffic between Docker bridge interfaces returns to Docker's own isolation and forwarding logic.
- New traffic initiated from `docker0` or `br-*` to the protected IPv4 LAN is dropped.
- Directly connected IPv6 prefixes on the external interface, including link-local scope, are derived at apply time and receive the same egress denial.
- Container-initiated traffic not destined for a protected LAN remains allowed, preserving internet access.
- Forwarded TCP 2375 and 2376 are always dropped.
- New public TCP 443 forwarding is allowed only when `ENABLE_PUBLIC_HTTPS=true`.
- Private management TCP ports are allowed only when `ENABLE_MANAGEMENT_PORTS=true` and the source matches the configured management allowlist.
- All other new traffic forwarded into a Docker bridge is dropped.

Jellyfin UDP discovery is not allowed. HTTPS deployment enables only public HTTPS; management exposure remains false. Host-network containers, fixed container addresses, raw Docker-socket exposure, and Docker's TCP API remain prohibited.

## Persistence and rollback

Apply installs:

- `/usr/local/sbin/veinfin-firewall` (`0755`, root-owned)
- `/etc/veinfin/firewall.conf` (`0600`, root-owned)
- `/etc/systemd/system/veinfin-firewall.service`
- `/etc/systemd/system/docker.service.d/veinfin-firewall.conf`

The enabled oneshot service applies policy after Docker. Docker's `ExecStartPost` hook reapplies it whenever Docker recreates its chains; this does not create a dependency cycle. Runtime reapplication waits briefly for one unambiguous IPv4 default route so an early DHCP boot race cannot fail Docker startup. Firewall `--apply` still requires an empty runtime, while `--verify` supports later deployed containers.

Before changing rules, apply saves exact root-only `iptables-save` and `ip6tables-save` snapshots under `/run`, records the prior VeinFin persistence files, and schedules a transient systemd rollback. A failed or interrupted apply restores the snapshots and previous files. If verification has not succeeded within five minutes, rollback runs automatically. If the session is lost, do not disable the timer; wait for restoration, reconnect, diagnose, and retry.

## Verification checklist

After apply, use a separate SSH session to run `--verify`, then confirm:

- SSH remains available from each approved management client. If a second approved client is unavailable, confirm its explicit source rule and report that no live connection was tested.
- DNS resolution, DHCP-held addressing/default routes, and a package download still work.
- TCP 443, application management ports, discovery, and Docker TCP API ports remain closed while their flags are off.
- `docker.service` and `veinfin-firewall.service` can each be restarted without losing either IPv4 or IPv6 policy.
- Docker still has no application containers or images before deployment.

firewall setup does not deploy the stack, publish a port, enable discovery, configure DNS/certificates/router mappings, change storage, or install another firewall manager. Enabling public HTTPS or private application ports is a later reviewed action after the corresponding services exist.
