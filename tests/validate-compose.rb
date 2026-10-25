#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
COMPOSE_PATH = File.join(ROOT, "compose.yaml")
JELLYFIN_LOOPBACK_PATH = File.join(ROOT, "compose", "jellyfin-loopback.yaml")
QBITTORRENT_LOOPBACK_PATH = File.join(ROOT, "compose", "qbittorrent-loopback.yaml")
ARR_LOOPBACK_PATH = File.join(ROOT, "compose", "arr-loopback.yaml")
MEDIA_SERVICES_LOOPBACK_PATH = File.join(ROOT, "compose", "media-services-loopback.yaml")
ENV_PATH = File.join(ROOT, ".env.example")
YAML_PATHS = Dir.glob(File.join(ROOT, "{compose.yaml,compose/*.yaml}"))
TEXT_PATHS = Dir.glob(File.join(ROOT, "{*.md,*.yaml,.env.example,.gitignore,compose/**/*.yaml,config/**/*,docs/**/*.md,install.sh,scripts/**/*.sh,templates/**/*}")).select { |path| File.file?(path) }

errors = []

def load_yaml(path)
  YAML.safe_load(File.read(path), aliases: true) || {}
rescue Psych::SyntaxError => e
  raise "#{path.delete_prefix(ROOT + "/")}: YAML syntax error: #{e.message}"
end

documents = {}
YAML_PATHS.each do |path|
  documents[path] = load_yaml(path)
end

compose = documents.fetch(COMPOSE_PATH)
services = compose.fetch("services", {})

if services.keys.any? { |name| name.match?(/plugin|who.?s.?watching/i) } || File.read(COMPOSE_PATH).match?(/WhoIsWatching|Who's Watching/i)
  errors << "default Compose must exclude experimental plugins and plugin installers"
end

expected_services = %w[
  reverse-proxy jellyfin qbittorrent sonarr radarr prowlarr bazarr seerr
  recyclarr flaresolverr
]
missing_services = expected_services - services.keys
errors << "missing Compose services: #{missing_services.join(', ')}" unless missing_services.empty?

declared_env = File.readlines(ENV_PATH, chomp: true).map do |line|
  match = line.match(/\A([A-Z][A-Z0-9_]*)=/)
  match && match[1]
end.compact.uniq

referenced_env = YAML_PATHS.flat_map do |path|
  File.read(path).scan(/\$\{([A-Z][A-Z0-9_]*)[^}]*\}/).flatten
end.uniq
missing_env = referenced_env - declared_env
errors << "undeclared environment variables: #{missing_env.sort.join(', ')}" unless missing_env.empty?

services.each do |name, service|
  image = service["image"]
  if image
    errors << "#{name}: image repository is implicit" unless image.include?("/") || image.start_with?("caddy:")
    errors << "#{name}: floating latest tag is forbidden" if image.match?(/:latest(?:@|\z)/i)
    errors << "#{name}: image must use a tag variable" unless image.match?(/\$\{[A-Z0-9_]+_IMAGE_TAG/)
  end

  errors << "#{name}: privileged containers are forbidden" if service["privileged"] == true
  errors << "#{name}: host networking is forbidden" if service["network_mode"] == "host"
  errors << "#{name}: container_name is unnecessary" if service.key?("container_name")

  Array(service["volumes"]).each do |volume|
    errors << "#{name}: direct Docker socket mount is forbidden" if volume.to_s.include?("/var/run/docker.sock")
  end
end

networks_text = compose.fetch("networks", {}).to_s
errors << "fixed container IP addresses are forbidden" if networks_text.match?(/ipv[46]_address/i)

published = services.flat_map do |name, service|
  Array(service["ports"]).map { |entry| [name, entry.to_s] }
end

if services.fetch("jellyfin", {}).key?("ports")
  errors << "Jellyfin must not publish a base-Compose host port"
end
if services.fetch("qbittorrent", {}).key?("ports")
  errors << "qBittorrent must not publish a base-Compose host port"
end
%w[sonarr radarr prowlarr].each do |name|
  errors << "#{name}: must not publish a base-Compose host port" if services.fetch(name, {}).key?("ports")
end
%w[bazarr seerr].each do |name|
  errors << "#{name}: must not publish a base-Compose host port" if services.fetch(name, {}).key?("ports")
end
if services.fetch("flaresolverr", {}).key?("ports")
  errors << "FlareSolverr must not publish a host port"
end

loopback = documents.fetch(JELLYFIN_LOOPBACK_PATH)
unless loopback.fetch("services", {}).keys == ["jellyfin"]
  errors << "compose/jellyfin-loopback.yaml must override only Jellyfin"
end
expected_loopback_port = {
  "name" => "jellyfin-bootstrap",
  "target" => 8096,
  "published" => "8096",
  "host_ip" => "127.0.0.1",
  "protocol" => "tcp"
}
unless Array(loopback.dig("services", "jellyfin", "ports")) == [expected_loopback_port]
  errors << "Jellyfin bootstrap override must publish only 127.0.0.1:8096:8096/tcp"
end

qbittorrent_loopback = documents.fetch(QBITTORRENT_LOOPBACK_PATH)
unless qbittorrent_loopback.fetch("services", {}).keys == ["qbittorrent"]
  errors << "compose/qbittorrent-loopback.yaml must override only qBittorrent"
end
expected_qbittorrent_port = {
  "name" => "qbittorrent-bootstrap",
  "target" => 8080,
  "published" => "8080",
  "host_ip" => "127.0.0.1",
  "protocol" => "tcp"
}
unless Array(qbittorrent_loopback.dig("services", "qbittorrent", "ports")) == [expected_qbittorrent_port]
  errors << "qBittorrent bootstrap override must publish only 127.0.0.1:8080:8080/tcp"
end

arr_loopback = documents.fetch(ARR_LOOPBACK_PATH)
expected_arr_ports = {
  "sonarr" => ["sonarr-bootstrap", 8989],
  "radarr" => ["radarr-bootstrap", 7878],
  "prowlarr" => ["prowlarr-bootstrap", 9696]
}
unless arr_loopback.fetch("services", {}).keys.sort == expected_arr_ports.keys.sort
  errors << "compose/arr-loopback.yaml must override only Sonarr, Radarr, and Prowlarr"
end
expected_arr_ports.each do |name, (port_name, port)|
  expected = [{"name" => port_name, "target" => port, "published" => port.to_s, "host_ip" => "127.0.0.1", "protocol" => "tcp"}]
  unless Array(arr_loopback.dig("services", name, "ports")) == expected
    errors << "#{name}: ARR deployment override must publish only 127.0.0.1:#{port}:#{port}/tcp"
  end
end

media_services_loopback = documents.fetch(MEDIA_SERVICES_LOOPBACK_PATH)
expected_media_services_ports = {
  "bazarr" => ["bazarr-bootstrap", 6767],
  "seerr" => ["seerr-bootstrap", 5055]
}
unless media_services_loopback.fetch("services", {}).keys.sort == expected_media_services_ports.keys.sort
  errors << "compose/media-services-loopback.yaml must override only Bazarr and Seerr"
end
expected_media_services_ports.each do |name, (port_name, port)|
  expected = [{"name" => port_name, "target" => port, "published" => port.to_s, "host_ip" => "127.0.0.1", "protocol" => "tcp"}]
  unless Array(media_services_loopback.dig("services", name, "ports")) == expected
    errors << "#{name}: Media services override must publish only 127.0.0.1:#{port}:#{port}/tcp"
  end
end

public_443 = published.select { |_name, entry| entry.match?(/:443(?::443)?\/tcp\z|:443\/tcp\z/) }
unless public_443.length == 1 && public_443.first.first == "reverse-proxy"
  errors << "only reverse-proxy may publish TCP 443"
end

caddy = services.fetch("reverse-proxy", {})
errors << "reverse-proxy: must run as upstream unprivileged user" unless caddy["user"] == "1000:1000"
errors << "reverse-proxy: root filesystem must be read-only" unless caddy["read_only"] == true
errors << "reverse-proxy: must drop all capabilities" unless Array(caddy["cap_drop"]) == ["ALL"]
errors << "reverse-proxy: only NET_BIND_SERVICE may be added" unless Array(caddy["cap_add"]) == ["NET_BIND_SERVICE"]
errors << "reverse-proxy: must attach only to proxy network" unless Array(caddy["networks"]) == ["proxy"]

if published.any? { |_name, entry| entry.match?(/:80(?::80)?\/tcp\z|:80\/tcp\z/) }
  errors << "TCP 80 must not be published by default"
end

expected_media_mounts = {
  "jellyfin" => ["${MEDIA_ROOT:?Set MEDIA_ROOT}/library:/data/library:ro"],
  "qbittorrent" => ["${MEDIA_ROOT:?Set MEDIA_ROOT}/torrents:/data/torrents"],
  "radarr" => ["${MEDIA_ROOT:?Set MEDIA_ROOT}:/data"],
  "sonarr" => ["${MEDIA_ROOT:?Set MEDIA_ROOT}:/data"],
  "bazarr" => [
    "${MEDIA_ROOT:?Set MEDIA_ROOT}/library/movies:/data/library/movies",
    "${MEDIA_ROOT:?Set MEDIA_ROOT}/library/tv:/data/library/tv",
    "${MEDIA_ROOT:?Set MEDIA_ROOT}/library/anime:/data/library/anime"
  ]
}

expected_media_mounts.each do |name, expected|
  actual = Array(services.fetch(name, {})["volumes"]).select { |mount| mount.to_s.include?("MEDIA_ROOT") }
  errors << "#{name}: media mounts must exactly equal #{expected.inspect}" unless actual == expected
end

%w[prowlarr flaresolverr seerr recyclarr reverse-proxy].each do |name|
  media_mount = Array(services.fetch(name, {})["volumes"]).find { |mount| mount.to_s.include?("MEDIA_ROOT") }
  errors << "#{name}: must not receive media storage" if media_mount
end

unless Array(services.fetch("prowlarr", {})["networks"]).include?("application") &&
       Array(services.fetch("flaresolverr", {})["networks"]).include?("application")
  errors << "Prowlarr and FlareSolverr must share the application network"
end

catalog_path = File.join(ROOT, "compose", "service-catalog.yaml")
catalog = documents.fetch(catalog_path)
required_fields = catalog.fetch("required_fields", [])
catalog.fetch("services", []).each_with_index do |entry, index|
  missing = required_fields.reject { |field| entry.key?(field) }
  errors << "service catalog entry #{index}: missing #{missing.join(', ')}" unless missing.empty?
end

env_values = File.readlines(ENV_PATH, chomp: true).map do |line|
  match = line.match(/\A([A-Z][A-Z0-9_]*)=(.*)\z/)
  match && [match[1], match[2]]
end.compact.to_h

image_tag_keys = services.values.map do |service|
  service.fetch("image", "").match(/\$\{([A-Z0-9_]+_IMAGE_TAG)/)&.captures&.first
end.compact
image_tag_keys.each do |key|
  value = env_values[key].to_s
  errors << "#{key}: unresolved image placeholder" if value.empty? || value.include?("__PIN_REQUIRED__")
  errors << "#{key}: floating latest tag is forbidden" if value.match?(/(?:^|:)latest(?:@|\z)/i)
  errors << "#{key}: expected tag plus sha256 digest" unless value.match?(/\A[^@]+@sha256:[0-9a-f]{64}\z/)
end

lock_path = File.join(ROOT, "config", "images.lock")
lock_values = File.readlines(lock_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.map do |line|
  key, _repository, tag, digest, platforms = line.split("|", 5)
  errors << "config/images.lock: malformed entry" unless key && tag && digest && platforms
  errors << "config/images.lock: #{key} lacks amd64" unless platforms.to_s.split(",").include?("amd64")
  [key, "#{tag}@#{digest}"]
end.to_h
image_tag_keys.each do |key|
  errors << "#{key}: .env.example and config/images.lock disagree" unless env_values[key] == lock_values[key]
end

secret_pattern = /(PASSWORD|API_KEY|PRIVATE_KEY|SECRET|TOKEN)\z/
env_values.each do |key, value|
  errors << "#{key}: example secret must be empty" if key.match?(secret_pattern) && !value.empty?
end

forbidden_credential_keys = %w[
  QBITTORRENT_PASSWORD CONTROL_PANEL_SESSION_SECRET SONARR_API_KEY RADARR_API_KEY
  PROWLARR_API_KEY BAZARR_API_KEY SEERR_API_KEY
]
forbidden_credential_keys.each do |key|
  errors << ".env.example: premature credential key #{key}" if env_values.key?(key)
end
errors << ".env.example: MANAGEMENT_PASSWORD contract is missing" unless env_values.key?("MANAGEMENT_PASSWORD")

supported_plugin_lock = File.read(File.join(ROOT, "config", "plugins.lock"))
plugin_entries = supported_plugin_lock.lines.grep_v(/^\s*(#|$)/).map { |line| line.chomp.split("|", 11) }
errors << "supported plugin lock must contain reviewed entries" if plugin_entries.empty?
plugin_entries.each do |entry|
  errors << "config/plugins.lock: malformed entry" unless entry.length == 11
  next unless entry.length == 11
  key, name, guid, version, abi, _license, repository, artifact, digest, restart, files = entry
  errors << "config/plugins.lock: invalid key" unless key.match?(/\A[A-Z][A-Z0-9_]+\z/)
  errors << "config/plugins.lock: invalid name" if name.empty?
  errors << "config/plugins.lock: invalid guid" unless guid.match?(/\A[0-9a-f-]{36}\z/)
  errors << "config/plugins.lock: invalid version" unless version.match?(/\A\d+\.\d+\.\d+\.\d+\z/) && abi.match?(/\A10\.11\.\d+\.\d+\z/)
  errors << "config/plugins.lock: repository is not official" unless repository.start_with?("https://github.com/")
  errors << "config/plugins.lock: artifact is not immutable" unless artifact.match?(%r{\Ahttps://(?:github\.com/.+/releases/download/|repo\.jellyfin\.org/files/plugin/).+\.zip\z})
  errors << "config/plugins.lock: invalid artifact digest" unless digest.match?(/\A[0-9a-f]{64}\z/)
  errors << "config/plugins.lock: restart contract missing" unless restart == "true"
  errors << "config/plugins.lock: invalid file hashes" unless files.split(",").all? { |file| file.match?(/\A[^=\/]+=([0-9a-f]{64})\z/) }
end
errors << "supported plugin lock contains a deferred plugin" if supported_plugin_lock.match?(/WhoIsWatching|Who's Watching|whos_watching/i)

installer_sources = [File.join(ROOT, "install.sh"), File.join(ROOT, "scripts", "installer.sh")] +
                    Dir.glob(File.join(ROOT, "scripts", "lib", "*.sh"))
installer_sources.each do |path|
  text = File.read(path)
  if text.match?(/WhoIsWatching|Who's Watching|whos_watching|experimental-plugins\.lock/i)
    errors << "#{path.delete_prefix(ROOT + '/')}: installer must exclude experimental plugins"
  end
end

config_script = File.read(File.join(ROOT, "scripts", "lib", "config.sh"))
errors << "qBittorrent must use the shared MANAGEMENT_PASSWORD contract" unless config_script.include?("including qBittorrent where supported")
errors << "bootstrap state must mark API keys pending" unless config_script.include?("SONARR_API_KEY=PENDING_BOOTSTRAP")
errors << "control-panel session secrets must not be generated" if config_script.include?("control-panel-session-secret")

forbidden_patterns = {
  "private infrastructure context" => /\b(?:Proxmox|hypervisor|CrowdSec|separate game server|Debian VM|Mac repository)\b/i,
  "private IPv4 address" => /\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.(?:\d{1,3}\.)\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3}\.)\d{1,3})\b/,
  "personal absolute path" => %r{/Users/[^\s`]+|/home/[^\s`]+},
  "dynamic-DNS hostname" => /\b[a-z0-9.-]+\.(?:duckdns\.org|ddns\.net|no-ip\.(?:org|com))\b/i,
  "host audit detail" => /\b(?:passwordless sudo|QEMU virtual|guest agent|nftables ruleset was empty)\b/i,
  "obsolete project name" => /VeinMedia|media-stack/i,
  "private key material" => /BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY/
}
TEXT_PATHS.each do |path|
  text = File.read(path)
  if path == File.join(ROOT, "config", "plugins.lock")
    text = text.lines.map do |line|
      fields = line.split("|", -1)
      fields[3] = "VERSION" if fields.length >= 4 && !line.start_with?("#")
      fields[4] = "ABI" if fields.length >= 5 && !line.start_with?("#")
      fields.join("|")
    end.join
  end
  forbidden_patterns.each do |label, pattern|
    errors << "#{path.delete_prefix(ROOT + '/')}: contains #{label}" if text.match?(pattern)
  end
end

ignore_lines = File.readlines(File.join(ROOT, ".gitignore"), chomp: true)
%w[.env runtime/ secrets/ state/ backups/ certificates/ .DS_Store __MACOSX/].each do |entry|
  errors << ".gitignore: missing #{entry}" unless ignore_lines.include?(entry)
end

if errors.empty?
  puts "storage preparation static validation passed (#{YAML_PATHS.length} YAML files, #{services.length} Compose services, #{lock_values.length} image locks)."
else
  warn errors.map { |error| "ERROR: #{error}" }.join("\n")
  exit 1
end
