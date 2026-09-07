#!/usr/bin/env ruby

require "json"
require "uri"

abort "usage: build-config.rb SUBSCRIPTION OUTPUT INDEX [RULES]" unless (3..4).cover?(ARGV.length)

subscription_path, output_path, index_text, rules_path = ARGV
rules_path ||= File.expand_path("../default-rules.json", __dir__)
index = Integer(index_text, 10)
lines = File.readlines(subscription_path, chomp: true).reject(&:empty?)
abort "server index is out of range" unless index.between?(1, lines.length)

uri = URI.parse(lines[index - 1])
abort "only vless:// subscriptions are supported" unless uri.scheme == "vless"

query = URI.decode_www_form(uri.query.to_s).to_h
vpn_outbound = {
  "type" => "vless",
  "tag" => "vpn",
  "server" => uri.host,
  "server_port" => uri.port,
  "uuid" => URI.decode_www_form_component(uri.user.to_s),
  "domain_resolver" => {
    "server" => "dns-direct",
    "strategy" => "prefer_ipv4"
  }
}
vpn_outbound["flow"] = query["flow"] unless query["flow"].to_s.empty?

if %w[tls reality].include?(query["security"])
  tls = {
    "enabled" => true,
    "server_name" => query["sni"].to_s.empty? ? uri.host : query["sni"]
  }
  unless query["fp"].to_s.empty?
    tls["utls"] = { "enabled" => true, "fingerprint" => query["fp"] }
  end
  if query["security"] == "reality"
    tls["reality"] = {
      "enabled" => true,
      "public_key" => query.fetch("pbk"),
      "short_id" => query.fetch("sid")
    }
  end
  vpn_outbound["tls"] = tls
end

case query["type"]
when nil, "", "tcp"
when "ws"
  vpn_outbound["transport"] = {
    "type" => "ws",
    "path" => query["path"].to_s.empty? ? "/" : query["path"],
    "headers" => query["host"].to_s.empty? ? {} : { "Host" => query["host"] }
  }
when "grpc"
  vpn_outbound["transport"] = {
    "type" => "grpc",
    "service_name" => query["serviceName"].to_s
  }
else
  abort "unsupported VLESS transport: #{query["type"]}"
end

rules_data = JSON.parse(File.read(rules_path))
routed_domains = Array(rules_data["domains"]).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
routed_apps = Array(rules_data["applications"]).map { |value| value.to_s.strip }.reject(&:empty?).uniq
routed_domains = routed_domains.map do |domain|
  domain = domain.delete_prefix("*.")
  abort "Invalid domain: use example.com or *.example.com" unless domain.length <= 253 && domain.split(".", -1).all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
  domain
end.uniq
paths = Array(rules_data["processPathRegexes"]).map(&:strip).reject(&:empty?).uniq
paths.each { |pattern| Regexp.new(pattern) }
full = rules_data.fetch("mode", "selective") == "all"
diagnostic_vpn_domains = ["api4.ipify.org"]
diagnostic_direct_domains = ["api64.ipify.org"]

dns_rules = [
  { "domain" => diagnostic_vpn_domains, "action" => "route", "server" => "dns-vpn", "strategy" => "prefer_ipv4" },
  { "domain" => diagnostic_direct_domains, "action" => "route", "server" => "dns-direct", "strategy" => "prefer_ipv4" }
]
unless paths.empty?
  dns_rules << { "process_path_regex" => paths, "action" => "route", "server" => "dns-vpn" }
end
unless routed_apps.empty?
  dns_rules << { "process_name" => routed_apps, "action" => "route", "server" => "dns-vpn" }
end
unless routed_domains.empty?
  dns_rules << { "domain_suffix" => routed_domains, "action" => "route", "server" => "dns-vpn" }
end

route_rules = [
  { "process_name" => ["sing-box"], "action" => "route", "outbound" => "direct" }
]
route_rules.concat([
  { "port" => 53, "action" => "hijack-dns" },
  { "action" => "sniff", "sniffer" => ["http", "tls", "quic", "dns"], "timeout" => "500ms" },
  { "protocol" => "dns", "action" => "hijack-dns" }
])
route_rules << { "domain" => diagnostic_direct_domains, "action" => "route", "outbound" => "direct" }
if full
  route_rules << { "domain_regex" => [".+"], "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" }
else
  route_rules << { "domain_suffix" => routed_domains, "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" } unless routed_domains.empty?
  route_rules << { "process_name" => routed_apps, "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" } unless routed_apps.empty?
  route_rules << { "process_path_regex" => paths, "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" } unless paths.empty?
end
route_rules << { "ip_is_private" => true, "action" => "route", "outbound" => "direct" }
route_rules << { "domain" => diagnostic_vpn_domains, "action" => "route", "outbound" => "vpn" }
route_rules << { "process_name" => routed_apps, "action" => "route", "outbound" => "vpn" } unless routed_apps.empty?
route_rules << { "process_path_regex" => paths, "action" => "route", "outbound" => "vpn" } unless paths.empty?
unless routed_domains.empty?
  route_rules << { "domain_suffix" => routed_domains, "action" => "route", "outbound" => "vpn" }
end

config = {
  "log" => { "level" => "warn", "timestamp" => true },
  "dns" => {
    "servers" => [
      {
        "type" => "local",
        "tag" => "dns-direct",
      },
      {
        "type" => "https",
        "tag" => "dns-vpn",
        "server" => "8.8.8.8",
        "server_port" => 443,
        "path" => "/dns-query",
        "tls" => { "enabled" => true, "server_name" => "dns.google" },
        "detour" => "vpn"
      }
    ],
    "strategy" => "prefer_ipv4",
    "rules" => dns_rules,
    "final" => full ? "dns-vpn" : "dns-direct",
    "reverse_mapping" => true
  },
  "inbounds" => [
    {
      "type" => "tun",
      "tag" => "tun-in",
      "address" => ["198.18.0.1/30"],
      "auto_route" => true,
      "strict_route" => true,
      "dns_mode" => "hijack",
      "dns_address" => ["198.18.0.2"],
      "stack" => "mixed",
      "mtu" => 1500,
      "route_exclude_address" => [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16"
      ]
    }
  ],
  "outbounds" => [
    vpn_outbound,
    {
      "type" => "direct",
      "tag" => "direct",
      "domain_resolver" => { "server" => "dns-direct", "strategy" => "prefer_ipv4" }
    }
  ],
  "route" => {
    "auto_detect_interface" => true,
    "rules" => route_rules,
    "final" => full ? "vpn" : "direct"
  }
}

File.write(output_path, JSON.pretty_generate(config) + "\n", mode: "w", perm: 0o600)
File.chmod(0o600, output_path)
