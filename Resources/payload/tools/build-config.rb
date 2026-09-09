#!/usr/bin/env ruby

require "json"
require "digest"
require "uri"

abort "usage: build-config.rb SUBSCRIPTION OUTPUT INDEX [RULES]" unless (3..4).cover?(ARGV.length)

subscription_path, output_path, index_text, rules_path = ARGV
rules_path ||= File.expand_path("../default-rules.json", __dir__)
File.delete(output_path + ".xray.json") if File.exist?(output_path + ".xray.json")
index = Integer(index_text, 10)
lines = File.readlines(subscription_path, chomp: true).reject(&:empty?)
abort "server index is out of range" unless index.between?(1, lines.length)

uri = URI.parse(lines[index - 1])
abort "only vless:// subscriptions are supported" unless uri.scheme == "vless"

query = URI.decode_www_form(uri.query.to_s).to_h
alpn = query["alpn"].to_s.split(",").map(&:strip).reject(&:empty?)
vpn_outbound = {
  "type" => "vless",
  "tag" => "vpn",
  "server" => uri.host,
  "server_port" => uri.port,
  "uuid" => URI.decode_www_form_component(uri.user.to_s),
  "domain_resolver" => {
    "server" => "dns-bootstrap",
    "strategy" => "prefer_ipv4"
  }
}
vpn_outbound["flow"] = query["flow"] unless query["flow"].to_s.empty?

xray_config = nil
requested_network = query["type"].to_s
xhttp = %w[xhttp splithttp].include?(requested_network)
if query["security"] == "reality" || xhttp
  if query["security"] == "reality"
    abort "REALITY requires pbk" if query["pbk"].to_s.empty?
    abort "REALITY public key is invalid" unless query["pbk"].match?(/\A[A-Za-z0-9_-]{43}\z/)
    abort "REALITY short ID is invalid" unless query["sid"].to_s.match?(/\A(?:[0-9a-fA-F]{2}){0,8}\z/)
  end

  network = requested_network
  network = "xhttp" if xhttp
  network = "raw" if network.empty? || %w[tcp raw].include?(network)
  security = query["security"].to_s
  security = "none" if security.empty?
  abort "unsupported VLESS XHTTP security: #{security}" unless %w[none tls reality].include?(security)
  stream = { "network" => network, "security" => security }
  case network
  when "raw"
  when "xhttp"
    host = query["host"].to_s
    abort "XHTTP host is invalid" if host.match?(/[\s\/?#@]/)
    mode = query["mode"].to_s.empty? ? "auto" : query["mode"]
    abort "unsupported XHTTP mode: #{mode}" unless %w[auto packet-up stream-up stream-one].include?(mode)
    xhttp_settings = {
      "host" => host,
      "path" => query["path"].to_s.empty? ? "/" : query["path"],
      "mode" => mode
    }
    unless query["extra"].to_s.empty?
      begin
        extra = JSON.parse(query["extra"])
      rescue JSON::ParserError
        abort "XHTTP extra must be valid JSON"
      end
      abort "XHTTP extra must be a JSON object" unless extra.is_a?(Hash)
      xhttp_settings["extra"] = extra
    end
    stream["xhttpSettings"] = xhttp_settings
  when "ws"
    stream["wsSettings"] = {
      "path" => query["path"].to_s.empty? ? "/" : query["path"],
      "headers" => query["host"].to_s.empty? ? {} : { "Host" => query["host"] }
    }
  when "grpc"
    stream["grpcSettings"] = { "serviceName" => query["serviceName"].to_s }
  else
    abort "unsupported VLESS REALITY transport: #{query["type"]}"
  end
  if security == "reality"
    reality = {
      "serverName" => query["sni"].to_s.empty? ? uri.host : query["sni"],
      "fingerprint" => query["fp"].to_s.empty? ? "chrome" : query["fp"],
      "password" => query["pbk"],
      "shortId" => query["sid"].to_s,
      "spiderX" => query["spx"].to_s
    }
    reality["mldsa65Verify"] = query["pqv"] unless query["pqv"].to_s.empty?
    stream["realitySettings"] = reality
  elsif security == "tls"
    tls = {
      "serverName" => query["sni"].to_s.empty? ? uri.host : query["sni"],
      "fingerprint" => query["fp"].to_s.empty? ? "chrome" : query["fp"]
    }
    tls["alpn"] = alpn unless alpn.empty?
    stream["tlsSettings"] = tls
  end
  user = {
    "id" => URI.decode_www_form_component(uri.user.to_s),
    "encryption" => query["encryption"].to_s.empty? ? "none" : query["encryption"]
  }
  user["flow"] = query["flow"] unless query["flow"].to_s.empty?
  xray_config = {
    "log" => { "loglevel" => "warning" },
    "inbounds" => [{
      "tag" => "matveev-reality-in",
      "listen" => "127.0.0.1",
      "port" => 18_443,
      "protocol" => "socks",
      "settings" => { "udp" => true }
    }],
    "outbounds" => [{
      "tag" => "reality",
      "protocol" => "vless",
      "settings" => { "vnext" => [{ "address" => uri.host, "port" => uri.port, "users" => [user] }] },
      "streamSettings" => stream
    }]
  }
  xray_path = output_path + ".xray.json"
  xray_json = JSON.pretty_generate(xray_config) + "\n"
  File.write(xray_path, xray_json, mode: "w", perm: 0o600)
  File.chmod(0o600, xray_path)
  vpn_outbound = {
    "type" => "socks",
    "tag" => "vpn",
    "server" => "127.0.0.1",
    "server_port" => 18_443,
    "version" => "5"
  }
end

if query["security"] == "tls" && xray_config.nil?
  tls = {
    "enabled" => true,
    "server_name" => query["sni"].to_s.empty? ? uri.host : query["sni"]
  }
  unless query["fp"].to_s.empty?
    tls["utls"] = { "enabled" => true, "fingerprint" => query["fp"] }
  end
  tls["alpn"] = alpn unless alpn.empty?
  vpn_outbound["tls"] = tls
end

case xray_config ? nil : query["type"]
when nil, "", "tcp", "raw"
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
  { "process_name" => ["sing-box", "xray"], "action" => "route", "outbound" => "direct" }
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
        "type" => "dhcp",
        "tag" => "dns-direct",
      },
      {
        "type" => "https",
        "tag" => "dns-bootstrap",
        "server" => "8.8.8.8",
        "server_port" => 443,
        "path" => "/dns-query",
        "tls" => { "enabled" => true, "server_name" => "dns.google" },
        "detour" => "direct"
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

if xray_config
  # Keep the primary config identity tied to the private sidecar so transaction
  # recovery can never confuse two Xray nodes that use the same local SOCKS endpoint.
  config["route"]["rules"].unshift({
    "process_name" => ["matveev-xray-config-#{Digest::SHA256.hexdigest(JSON.generate(xray_config))}"],
    "action" => "route",
    "outbound" => "direct"
  })
end

File.write(output_path, JSON.pretty_generate(config) + "\n", mode: "w", perm: 0o600)
File.chmod(0o600, output_path)
