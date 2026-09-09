require 'json'
require 'tmpdir'
require 'rbconfig'
require 'uri'

defaults_path = File.expand_path('../Resources/payload/default-rules.json', __dir__)
defaults = JSON.parse(File.read(defaults_path))
expected_domains = %w[youtube.com googlevideo.com telegram.org chatgpt.com openai.com claude.ai anthropic.com cursor.com cursor.sh]
missing_domains = expected_domains - defaults.fetch('domains')
raise "default service domains missing: #{missing_domains.join(', ')}" unless missing_domains.empty?
expected_apps = %w[ChatGPT Codex Claude Telegram Cursor]
missing_apps = expected_apps - defaults.fetch('applications')
raise "default applications missing: #{missing_apps.join(', ')}" unless missing_apps.empty?
raise 'Cursor helper path is missing from defaults' unless defaults.fetch('processPathRegexes').include?('^.*/Cursor\\.app/Contents/.*')

Dir.mktmpdir('matveev-routing') do |dir|
  sub, rules, config = %w[sub rules config].map { |name| File.join(dir, name) }
  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls#Test\n")
  builder = File.expand_path('../Resources/payload/tools/build-config.rb', __dir__)
  %w[selective all].each do |mode|
    File.write(rules, JSON.generate({domains: ['*.example.com'], applications: ['Example'], processPathRegexes: ['^.*/Cursor\\.app/Contents/.*'], mode: mode}))
    raise 'generation failed' unless system(RbConfig.ruby, builder, sub, config, '1', rules)
    value = JSON.parse(File.read(config))
    raise 'wrong final' unless value['route']['final'] == (mode == 'all' ? 'vpn' : 'direct')
    raise 'wrong DNS final' unless value['dns']['final'] == (mode == 'all' ? 'dns-vpn' : 'dns-direct')
    direct_dns = value['dns']['servers'].find { |server| server['tag'] == 'dns-direct' }
    raise 'direct DNS must read DHCP without using the overridden system resolver' unless direct_dns && direct_dns['type'] == 'dhcp'
    raise 'recursive local DNS bootstrap was reintroduced' if value['dns']['servers'].any? { |server| server['type'] == 'local' }
    raise 'VPN server must use an independent bootstrap resolver' unless value['outbounds'][0]['domain_resolver']['server'] == 'dns-bootstrap'
    bootstrap = value['dns']['servers'].find { |server| server['tag'] == 'dns-bootstrap' }
    raise 'VPN bootstrap must use direct HTTPS with a numeric address' unless bootstrap && bootstrap['type'] == 'https' && bootstrap['server'] == '8.8.8.8' && bootstrap['server_port'] == 443 && bootstrap['detour'] == 'direct'
    raise 'external UDP bootstrap DNS was reintroduced' if value['dns']['servers'].any? { |server| server['tag'] == 'dns-bootstrap' && server['type'] == 'udp' }
    raise 'IPv6 TUN regression was reintroduced' if value['inbounds'][0]['address'].any? { |a| a.include?(':') }
    raise 'private routes must bypass TUN' unless value['inbounds'][0]['route_exclude_address'] == ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
    raise 'DNS should prefer IPv4 without returning NXDOMAIN for IPv6 queries' unless value['dns']['strategy'] == 'prefer_ipv4'
    raise 'native TUN DNS hijacking is missing' unless value['inbounds'][0]['dns_mode'] == 'hijack'
    raise 'system DNS and TUN resolver addresses differ' unless value['inbounds'][0]['dns_address'] == ['198.18.0.2']
    route = value['route']['rules']
    raise 'wildcard not normalized' unless route.any? { |r| r['domain_suffix'] == ['example.com'] }
    resolver = mode == 'all' ? route.find { |r| r['domain_regex'] == ['.+'] && r['action'] == 'resolve' } : route.find { |r| r['domain_suffix'] == ['example.com'] && r['action'] == 'resolve' }
    raise 'routed destinations are not re-resolved through VPN DNS' unless resolver && resolver['server'] == 'dns-vpn' && resolver['strategy'] == 'prefer_ipv4'
    raise 'destination is routed before secure re-resolution' unless route.index(resolver) < route.index { |r| r['domain_suffix'] == ['example.com'] && r['outbound'] == 'vpn' }
    raise 'VPN diagnostic endpoint does not use VPN' unless route.any? { |r| r['domain'] == ['api4.ipify.org'] && r['outbound'] == 'vpn' }
    raise 'direct diagnostic endpoint does not bypass VPN' unless route.any? { |r| r['domain'] == ['api64.ipify.org'] && r['outbound'] == 'direct' }
    raise 'diagnostic DNS does not use VPN' unless value['dns']['rules'].any? { |r| r['domain'] == ['api4.ipify.org'] && r['server'] == 'dns-vpn' }
    raise 'DNS intercepted after process route' unless route.index { |r| r['action'] == 'hijack-dns' } < route.index { |r| r['process_name'] == ['Example'] }
    raise 'process path missing in DNS' unless value['dns']['rules'].any? { |r| r.key?('process_path_regex') }
  end
  ['api.*.example.com', 'https://example.com/a', '*example.com', 'foo..com'].each do |domain|
    File.write(rules, JSON.generate({domains: [domain]}))
    raise "invalid domain accepted: #{domain}" if system(RbConfig.ruby, builder, sub, config, '1', rules, out: File::NULL, err: File::NULL)
  end

  raise 'default generation failed' unless system(RbConfig.ruby, builder, sub, config, '1')
  generated_defaults = JSON.parse(File.read(config))
  default_route = generated_defaults.fetch('route').fetch('rules').find { |rule| rule['outbound'] == 'vpn' && rule.key?('domain_suffix') }
  raise 'bundled defaults are not applied by the config generator' unless default_route && expected_domains.all? { |domain| default_route['domain_suffix'].include?(domain) }
  raise 'bundled Cursor helper route is missing' unless generated_defaults.fetch('route').fetch('rules').any? { |rule| rule['outbound'] == 'vpn' && rule['process_path_regex']&.include?('^.*/Cursor\\.app/Contents/.*') }

  File.write(rules, JSON.generate({domains: ['example.com'], applications: [], processPathRegexes: [], mode: 'selective'}))
  reality_key = 'A' * 43
  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@reality.example.com:443?type=raw&security=reality&encryption=none&flow=xtls-rprx-vision&fp=chrome&sni=cover.example.com&pbk=#{reality_key}&sid=0123456789abcdef&spx=%2Fmodern#Reality\n")
  raise 'REALITY generation failed' unless system(RbConfig.ruby, builder, sub, config, '1', rules)
  reality_main = JSON.parse(File.read(config))
  reality_sidecar = JSON.parse(File.read(config + '.xray.json'))
  vpn = reality_main.fetch('outbounds').find { |outbound| outbound['tag'] == 'vpn' }
  raise 'REALITY must use the private Xray transport' unless vpn == {'type' => 'socks', 'tag' => 'vpn', 'server' => '127.0.0.1', 'server_port' => 18_443, 'version' => '5'}
  raise 'Xray loop prevention is missing' unless reality_main.fetch('route').fetch('rules').any? { |rule| rule['process_name']&.include?('xray') && rule['outbound'] == 'direct' }
  stream = reality_sidecar.fetch('outbounds').first.fetch('streamSettings')
  settings = stream.fetch('realitySettings')
  raise 'modern raw transport was not preserved' unless stream['network'] == 'raw'
  raise 'REALITY parameters were not preserved' unless settings['serverName'] == 'cover.example.com' && settings['password'] == reality_key && settings['shortId'] == '0123456789abcdef' && settings['spiderX'] == '/modern'
  marker = reality_main.fetch('route').fetch('rules').first.fetch('process_name').first
  raise 'sidecar transaction marker is missing' unless marker.start_with?('matveev-xray-config-')

  xhttp_extra = {xPaddingBytes: '100-1000', noGRPCHeader: false}
  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@xhttp.example.com:443?type=xhttp&security=reality&encryption=none&flow=xtls-rprx-vision&fp=chrome&sni=cover.example.com&pbk=#{reality_key}&sid=0123456789abcdef&path=%2Fhidden&host=cdn.example.com&mode=stream-up&extra=#{URI.encode_www_form_component(JSON.generate(xhttp_extra))}#XHTTP-Reality\n")
  raise 'XHTTP REALITY generation failed' unless system(RbConfig.ruby, builder, sub, config, '1', rules)
  xhttp_reality = JSON.parse(File.read(config + '.xray.json')).fetch('outbounds').first.fetch('streamSettings')
  raise 'XHTTP transport was not generated' unless xhttp_reality['network'] == 'xhttp'
  raise 'XHTTP settings were not preserved' unless xhttp_reality['xhttpSettings'] == {'host' => 'cdn.example.com', 'path' => '/hidden', 'mode' => 'stream-up', 'extra' => {'xPaddingBytes' => '100-1000', 'noGRPCHeader' => false}}
  raise 'XHTTP REALITY security was lost' unless xhttp_reality['security'] == 'reality' && xhttp_reality['realitySettings']['password'] == reality_key

  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@tls.example.com:443?type=splithttp&security=tls&encryption=none&fp=chrome&sni=edge.example.com&alpn=h2%2Chttp%2F1.1&path=%2Fx&host=edge.example.com&mode=auto#XHTTP-TLS\n")
  raise 'XHTTP TLS generation failed' unless system(RbConfig.ruby, builder, sub, config, '1', rules)
  xhttp_tls = JSON.parse(File.read(config + '.xray.json')).fetch('outbounds').first.fetch('streamSettings')
  raise 'SplitHTTP alias was not normalized' unless xhttp_tls['network'] == 'xhttp'
  raise 'XHTTP TLS settings were not preserved' unless xhttp_tls['tlsSettings'] == {'serverName' => 'edge.example.com', 'fingerprint' => 'chrome', 'alpn' => ['h2', 'http/1.1']}

  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@tls.example.com:443?type=xhttp&security=tls&encryption=none&host=bad.example.com%2Fcrash#Invalid-XHTTP\n")
  raise 'unsafe XHTTP host was accepted' if system(RbConfig.ruby, builder, sub, config, '1', rules, out: File::NULL, err: File::NULL)

  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=raw&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1#Raw-TLS\n")
  raise 'raw TLS generation failed' unless system(RbConfig.ruby, builder, sub, config, '1', rules)
  raw_tls = JSON.parse(File.read(config)).fetch('outbounds').first
  raise 'raw alias created a redundant transport' if raw_tls.key?('transport')
  raise 'raw TLS ALPN was not preserved' unless raw_tls.fetch('tls')['alpn'] == ['h2', 'http/1.1']
  raise 'stale Xray sidecar was retained' if File.exist?(config + '.xray.json')

  File.write(sub, "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=ws&security=tls&path=%2Fsocket&alpn=http%2F1.1#WebSocket-TLS\n")
  raise 'WebSocket TLS generation failed' unless system(RbConfig.ruby, builder, sub, config, '1', rules)
  ws_tls = JSON.parse(File.read(config)).fetch('outbounds').first
  raise 'TLS ALPN was not applied to WebSocket' unless ws_tls.fetch('transport')['type'] == 'ws' && ws_tls.fetch('tls')['alpn'] == ['http/1.1']
end
puts 'routing: defaults, modes, secure DNS, Xray transports, TLS aliases, wildcards and process paths passed'
