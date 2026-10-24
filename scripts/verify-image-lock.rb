#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

ROOT = File.expand_path("..", __dir__)
LOCK_PATH = File.join(ROOT, "config", "images.lock")
ACCEPT = [
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.list.v2+json"
].join(", ")

def get(uri, headers = {})
  target = URI(uri)
  request = Net::HTTP::Get.new(target)
  headers.each { |name, value| request[name] = value }
  Net::HTTP.start(target.host, target.port, use_ssl: true) do |http|
    http.open_timeout = 10
    http.read_timeout = 30
    http.request(request)
  end
end

def registry_contract(repository)
  case repository
  when "caddy", "python"
    ["registry-1.docker.io", "library/#{repository}", "https://auth.docker.io/token?service=registry.docker.io"]
  when "jellyfin/jellyfin"
    ["registry-1.docker.io", repository, "https://auth.docker.io/token?service=registry.docker.io"]
  when %r{\Alscr\.io/(.+)\z}
    ["ghcr.io", Regexp.last_match(1), "https://ghcr.io/token?service=ghcr.io"]
  when %r{\Aghcr\.io/(.+)\z}
    ["ghcr.io", Regexp.last_match(1).downcase, "https://ghcr.io/token?service=ghcr.io"]
  else
    raise "unsupported official registry repository: #{repository}"
  end
end

def verify(repository, tag, expected_digest)
  registry, registry_repository, token_url = registry_contract(repository)
  scope = "repository:#{registry_repository}:pull"
  token_response = get("#{token_url}&scope=#{URI.encode_www_form_component(scope)}")
  raise "registry token request returned HTTP #{token_response.code}" unless token_response.is_a?(Net::HTTPSuccess)

  token = JSON.parse(token_response.body).fetch("token")
  manifest = get(
    "https://#{registry}/v2/#{registry_repository}/manifests/#{URI.encode_www_form_component(tag)}",
    "Authorization" => "Bearer #{token}",
    "Accept" => ACCEPT
  )
  raise "manifest request returned HTTP #{manifest.code}" unless manifest.is_a?(Net::HTTPSuccess)

  actual_digest = manifest["docker-content-digest"]
  index = JSON.parse(manifest.body)
  platforms = Array(index["manifests"]).map { |entry| entry["platform"] }.compact
  has_amd64 = platforms.any? { |platform| platform["os"] == "linux" && platform["architecture"] == "amd64" }
  raise "tag digest drifted: expected #{expected_digest}, received #{actual_digest}" unless actual_digest == expected_digest
  raise "multi-architecture manifest no longer includes linux/amd64" unless has_amd64
end

if ARGV == ["--help"]
  puts "Usage: scripts/verify-image-lock.rb"
  puts "Checks locked tags against their official registries without changing the lock."
  exit 0
end
abort "Usage: scripts/verify-image-lock.rb" unless ARGV.empty?

failures = []
checked = 0
File.foreach(LOCK_PATH, chomp: true) do |line|
  next if line.empty? || line.start_with?("#")

  key, repository, tag, digest, platforms = line.split("|", 5)
  unless key && repository && tag && digest&.match?(/\Asha256:[0-9a-f]{64}\z/) && platforms
    failures << "malformed lock entry: #{key || "unknown"}"
    next
  end

  begin
    verify(repository, tag, digest)
    checked += 1
    puts "PASS: #{key} matches the official registry manifest and includes linux/amd64"
  rescue StandardError => e
    failures << "#{key}: #{e.message}"
  end
end

if failures.empty?
  puts "Image lock verification passed: #{checked} entries."
else
  warn failures.map { |failure| "FAIL: #{failure}" }.join("\n")
  exit 1
end
