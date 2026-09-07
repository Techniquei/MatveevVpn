require 'json'
require 'tmpdir'
require 'rbconfig'

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
    raise 'VPN server must use the direct system resolver' unless value['outbounds'][0]['domain_resolver']['server'] == 'dns-direct'
    raise 'external UDP bootstrap DNS was reintroduced' if value['dns']['servers'].any? { |r| r['tag'] == 'dns-bootstrap' }
    raise 'IPv6 TUN regression was reintroduced' if value['inbounds'][0]['address'].any? { |a| a.include?(':') }
    raise 'private routes must bypass TUN' unless value['inbounds'][0]['route_exclude_address'] == ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
    raise 'DNS must suppress unsupported IPv6' unless value['dns']['strategy'] == 'ipv4_only'
    route = value['route']['rules']
    raise 'wildcard not normalized' unless route.any? { |r| r['domain_suffix'] == ['example.com'] }
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
end
puts 'routing: modes, DNS ordering, IPv4 compatibility, wildcards and process paths passed'
