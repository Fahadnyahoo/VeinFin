# Optional and deferred work

The default VeinFin stack is implemented through the one-command installer. The following items are intentionally outside the supported installation path:

The private control panel and restricted lifecycle agent are supported parts of the installed stack.

- **Who’s Watching:** deferred after browser-session behavior could not be validated reliably. Experimental source pins and patch research remain isolated, disabled, and excluded from installation.
- **VPN routing:** the example Compose override is documentation-only until a provider-specific design is reviewed.
- **Hardware transcoding:** enabled only when the host provides a validated render device and the operator opts in.
- **Live synthetic torrent validation:** excluded from installation; download lifecycle configuration is verified without creating a torrent.
- **Clean-host platform expansion:** Debian is the supported host. Other distributions require separate testing.

Optional work must preserve the documented exposure, storage, secret, and least-privilege boundaries.
