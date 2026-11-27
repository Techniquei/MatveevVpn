#!/usr/bin/env ruby

require "base64"
require "json"
require "digest"
require "uri"

abort "usage: build-config.rb SUBSCRIPTION OUTPUT INDEX RULES [--sing-box-reality]" unless ARGV.length == 4 || (ARGV.length == 5 && ARGV.last == "--sing-box-reality")

subscription_path, output_path, index_text, rules_path, reality_mode = ARGV
File.delete(output_path + ".xray.json") if File.exist?(output_path + ".xray.json")
index = Integer(index_text, 10)
lines = File.readlines(subscription_path, chomp: true).reject(&:empty?)
if index.zero? && lines.empty?
  # First-launch provisioning has no listener, tunnel or DNS policy. The controller
  # stays stopped until the coordinator deploys a validated subscription.
  JSON.parse(File.read(rules_path))
  config = { "log" => { "level" => "warn" }, "inbounds" => [], "outbounds" => [{ "type" => "direct", "tag" => "direct" }] }
  File.write(output_path, JSON.pretty_generate(config) + "\n", mode: "w", perm: 0o600)
  File.chmod(0o600, output_path)
  exit
end
abort "server index is out of range" unless index.between?(1, lines.length)

def hysteria2_outbound(uri, query)
  host = uri.hostname
  port = uri.port || 443
  abort "Invalid Hysteria 2 hostname or port" unless host && !host.empty? && port.between?(1, 65_535)
  abort "Unsupported Hysteria 2 path" unless ["", "/"].include?(uri.path)

  # User info is URI-escaped, so a literal plus is part of the credential.
  password = URI::DEFAULT_PARSER.unescape(uri.userinfo.to_s)
  abort "Hysteria 2 requires authentication" if password.empty?
  tls = { "enabled" => true, "server_name" => query["sni"].to_s.empty? ? host : query["sni"] }
  if query.key?("pinSHA256")
    pin = query.fetch("pinSHA256")
    abort "Invalid Hysteria 2 certificate fingerprint" unless pin.match?(/\A(?:[0-9a-f]{64}|(?:[0-9a-f]{2}:){31}[0-9a-f]{2})\z/i)
    # Hysteria pins the entire leaf certificate, rather than its public key.
    tls["certificate_sha256"] = [Base64.strict_encode64([pin.delete(":")].pack("H*"))]
  elsif query["insecure"] == "1"
    tls["insecure"] = true
  end

  outbound = {
    "type" => "hysteria2",
    "tag" => "vpn",
    "server" => host,
    "server_port" => port,
    "password" => password,
    "tls" => tls,
    "domain_resolver" => { "server" => "dns-direct", "strategy" => "prefer_ipv4" }
  }
  unless query["obfs"].to_s.empty?
    abort "Unsupported Hysteria 2 obfuscation" unless %w[salamander gecko].include?(query["obfs"])
    abort "Hysteria 2 obfuscation requires a password" if query["obfs-password"].to_s.empty?
    outbound["obfs"] = { "type" => query["obfs"], "password" => query["obfs-password"] }
  end
  abort "Hysteria 2 port hopping is unsupported" unless query["mport"].to_s.empty?
  abort "Hysteria 2 ECH is unsupported" unless query["ech"].to_s.empty?
  outbound
end

def vless_outbound(uri, query, output_path, reality_mode)
  alpn = query["alpn"].to_s.split(",").map(&:strip).reject(&:empty?)
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

  xray_config = nil
  requested_network = query["type"].to_s
  xhttp = %w[xhttp splithttp].include?(requested_network)
  reality = query["security"] == "reality"
  if reality
    abort "REALITY requires pbk" if query["pbk"].to_s.empty?
    abort "REALITY public key is invalid" unless query["pbk"].match?(/\A[A-Za-z0-9_-]{43}\z/)
    abort "REALITY short ID is invalid" unless query["sid"].to_s.match?(/\A(?:[0-9a-fA-F]{2}){0,8}\z/)
  end

  if reality_mode
    abort "sing-box REALITY requires TCP, unencrypted VLESS framing and no PQ verification" unless reality &&
      ["", "tcp", "raw"].include?(requested_network) && ["", "none"].include?(query["encryption"].to_s) &&
      ["", "xtls-rprx-vision"].include?(query["flow"].to_s) && query["pqv"].to_s.empty?
    vpn_outbound["tls"] = {
      "enabled" => true,
      "server_name" => query["sni"].to_s.empty? ? uri.host : query["sni"],
      "utls" => { "enabled" => true, "fingerprint" => query["fp"].to_s.empty? ? "chrome" : query["fp"] },
      "reality" => { "enabled" => true, "public_key" => query["pbk"], "short_id" => query["sid"].to_s }
    }
  elsif reality || xhttp
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
        "settings" => {
          "vnext" => [{ "address" => uri.host, "port" => uri.port, "users" => [user] }],
          "domainStrategy" => "UseIPv4"
        },
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
  [vpn_outbound, xray_config]
end

begin
  uri = URI.parse(lines[index - 1])
  query = URI.decode_www_form(uri.query.to_s).to_h
rescue URI::Error, ArgumentError
  abort "Invalid VPN link"
end

case uri.scheme
when "vless"
  vpn_outbound, xray_config = vless_outbound(uri, query, output_path, reality_mode)
when "hysteria2", "hy2"
  vpn_outbound = hysteria2_outbound(uri, query)
else
  abort "Unsupported VPN link protocol"
end

rules_data = JSON.parse(File.read(rules_path))
automatic_service_catalog = %w[
  youtube telegram whatsapp instagram facebook twitter discord openai anthropic
  google-gemini cursor github-copilot spotify
].freeze
automatic_enabled = rules_data.fetch("automaticRoutingEnabled", true)
ad_blocking_enabled = rules_data.fetch("adBlockingEnabled", false)
ad_block_domains = []
if ad_blocking_enabled
  ad_block_path = File.join(File.dirname(rules_path), "ad-block-domains.txt")
  abort "Advertising rule data is missing" unless File.file?(ad_block_path)
  ad_block_domains = File.readlines(ad_block_path, chomp: true).map(&:strip).reject { |value| value.empty? || value.start_with?("#") }.map(&:downcase).uniq
  abort "Advertising rule data is unexpectedly small" if ad_block_domains.empty?
  ad_block_domains.each do |domain|
    abort "Invalid advertising domain" unless domain.length <= 253 && domain.split(".", -1).length >= 2 && domain.split(".", -1).all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
  end
end
requested_services = Array(rules_data.fetch("automaticServices", automatic_service_catalog)).map { |value| value.to_s.strip }.reject(&:empty?).uniq
unknown_services = requested_services - automatic_service_catalog
abort "Unsupported service preset: #{unknown_services.first}" unless unknown_services.empty?
routed_domains = Array(rules_data["domains"]).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
routed_domains = routed_domains.map do |domain|
  domain = domain.delete_prefix("*.")
  abort "Invalid domain: use example.com or *.example.com" unless domain.length <= 253 && domain.split(".", -1).all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
  domain
end.uniq
full = rules_data.fetch("mode", "selective") == "all"
automatic_services = automatic_enabled && !full ? automatic_service_catalog.select { |service| requested_services.include?(service) } : []
domain_rule_set_tags = automatic_services.map { |service| "preset-#{service}" }
ip_rule_set_services = automatic_services & %w[telegram facebook twitter]
ip_rule_set_tags = ip_rule_set_services.map { |service| "preset-#{service}-ip" }
remote_rule_sets = automatic_services.map do |service|
  {
    "type" => "remote",
    "tag" => "preset-#{service}",
    "format" => "binary",
    "url" => "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/#{service}.srs",
    "http_client" => "rules-download",
    "update_interval" => "1d"
  }
end
remote_rule_sets.concat(ip_rule_set_services.map do |service|
  {
    "type" => "remote",
    "tag" => "preset-#{service}-ip",
    "format" => "binary",
    "url" => "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/#{service}.srs",
    "http_client" => "rules-download",
    "update_interval" => "1d"
  }
end)
rule_sets = remote_rule_sets.dup
if ad_blocking_enabled
  rule_sets << {
    "type" => "inline",
    "tag" => "ad-block",
    "rules" => [{ "domain_suffix" => ad_block_domains }]
  }
end
diagnostic_vpn_domains = ["api4.ipify.org"]
diagnostic_direct_domains = ["api64.ipify.org"]
ad_block_update_domains = ["raw.githubusercontent.com"]

def direct_dns_rules(match, cache: true)
  options = cache ? {} : { "disable_cache" => true }
  [
    match.merge(options, "action" => "evaluate", "server" => "dns-direct", "timeout" => "1200ms"),
    { "match_response" => true, "response_rcode" => "NOERROR", "action" => "respond" },
    { "match_response" => true, "response_rcode" => "NXDOMAIN", "action" => "respond" },
    match.merge(options, "action" => "route", "server" => "dns-direct-backup", "timeout" => "1400ms")
  ]
end

# Health checks must reach the resolver rather than accept an old cached answer.
dns_rules = [
  { "domain" => diagnostic_vpn_domains, "action" => "route", "server" => "dns-vpn", "disable_cache" => true }
]
dns_rules.concat(direct_dns_rules({ "domain" => diagnostic_direct_domains }, cache: false))
dns_rules << { "domain" => ad_block_update_domains, "action" => "route", "server" => "dns-vpn" } if ad_blocking_enabled
dns_rules << { "rule_set" => ["ad-block"], "action" => "reject" } if ad_blocking_enabled
unless routed_domains.empty?
  dns_rules << { "domain_suffix" => routed_domains, "action" => "route", "server" => "dns-vpn" }
end
unless domain_rule_set_tags.empty?
  dns_rules << { "rule_set" => domain_rule_set_tags, "action" => "route", "server" => "dns-vpn" }
end
dns_rules.concat(direct_dns_rules({})) unless full

route_rules = [
  { "process_name" => ["sing-box", "xray"], "action" => "route", "outbound" => "direct" }
]
route_rules.concat([
  { "port" => 53, "action" => "hijack-dns" },
  { "action" => "sniff", "sniffer" => ["http", "tls", "quic", "dns"], "timeout" => "500ms" },
  { "protocol" => "dns", "action" => "hijack-dns" }
])
route_rules << { "rule_set" => ["ad-block"], "action" => "reject" } if ad_blocking_enabled
route_rules << { "domain" => diagnostic_direct_domains, "action" => "route", "outbound" => "direct" }
if full
  route_rules << { "domain_regex" => [".+"], "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" }
else
  route_rules << { "rule_set" => domain_rule_set_tags, "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" } unless domain_rule_set_tags.empty?
  route_rules << { "domain_suffix" => routed_domains, "action" => "resolve", "server" => "dns-vpn", "strategy" => "prefer_ipv4" } unless routed_domains.empty?
end
route_rules << { "ip_is_private" => true, "action" => "route", "outbound" => "direct" }
route_rules << { "domain" => diagnostic_vpn_domains, "action" => "route", "outbound" => "vpn" }
route_rules << { "domain" => ad_block_update_domains, "action" => "route", "outbound" => "vpn" } if ad_blocking_enabled
unless routed_domains.empty?
  route_rules << { "domain_suffix" => routed_domains, "action" => "route", "outbound" => "vpn" }
end
all_rule_set_tags = domain_rule_set_tags + ip_rule_set_tags
route_rules << { "rule_set" => all_rule_set_tags, "action" => "route", "outbound" => "vpn" } unless all_rule_set_tags.empty?

config = {
  # Remote preset success events let the controller publish their last refresh.
  "log" => { "level" => remote_rule_sets.empty? ? "warn" : "info", "timestamp" => true },
  "dns" => {
    "servers" => [
      {
        "type" => "https",
        "tag" => "dns-direct",
        "server" => "8.8.8.8",
        "server_port" => 443,
        "path" => "/dns-query",
        "tls" => { "enabled" => true, "server_name" => "dns.google" },
        "detour" => "direct"
      },
      {
        "type" => "https",
        "tag" => "dns-direct-backup",
        "server" => "1.1.1.1",
        "server_port" => 443,
        "path" => "/dns-query",
        "tls" => { "enabled" => true, "server_name" => "cloudflare-dns.com" },
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

config["route"]["rule_set"] = rule_sets unless rule_sets.empty?

unless remote_rule_sets.empty?
  config["http_clients"] = [{ "tag" => "rules-download", "detour" => "vpn" }]
  config["experimental"] = {
    "cache_file" => {
      "enabled" => true,
      "path" => "/Library/Application Support/matveevVpn/run/rule-set-cache.db"
    }
  }
end

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
