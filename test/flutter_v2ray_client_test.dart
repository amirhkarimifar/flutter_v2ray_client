import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:flutter_v2ray_client/url/vless.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('V2ray URL Parsing Tests', () {
    test('should parse vmess URL correctly', () {
      const vmessUrl =
          'vmess://eyJ2IjoiMiIsInBzIjoiVGVzdCBTZXJ2ZXIiLCJhZGQiOiIxMC4wLjAuMSIsInBvcnQiOiI0NDMiLCJpZCI6IjEyMzQ1Njc4LWFiY2QtMTIzNC1hYmNkLTEyMzQ1Njc4YWJjZCIsImFpZCI6IjAiLCJuZXQiOiJ0Y3AiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiIiLCJwYXRoIjoiIiwidGxzIjoiIn0=';

      expect(() => V2ray.parseFromURL(vmessUrl), returnsNormally);
      final parsed = V2ray.parseFromURL(vmessUrl);
      expect(parsed, isA<V2RayURL>());
      expect(parsed.remark, equals('Test Server'));
    });

    test('should parse vless URL correctly', () {
      const vlessUrl =
          'vless://12345678-abcd-1234-abcd-12345678abcd@10.0.0.1:443?type=tcp&security=tls&sni=example.com#Test VLESS';

      expect(() => V2ray.parseFromURL(vlessUrl), returnsNormally);
      final parsed = V2ray.parseFromURL(vlessUrl);
      expect(parsed, isA<V2RayURL>());
      expect(parsed.remark, equals('Test VLESS'));
    });

    test('should throw ArgumentError for invalid URL', () {
      const invalidUrl = 'invalid://url';

      expect(() => V2ray.parseFromURL(invalidUrl), throwsArgumentError);
    });

    test('should throw ArgumentError for unsupported protocol', () {
      const unsupportedUrl = 'unsupported://example.com';

      expect(() => V2ray.parseFromURL(unsupportedUrl), throwsArgumentError);
    });
  });

  group('V2ray Configuration Validation Tests', () {
    late V2ray v2ray;
    const channel = MethodChannel('flutter_v2ray_client');

    setUp(() {
      v2ray = V2ray(onStatusChanged: (_) {});
      // Without a handler the platform call rejects, and the rejection
      // surfaces as an unhandled async error rather than a test failure that
      // says anything useful. These tests are about the JSON validation that
      // happens before the channel is ever reached.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return call.method == 'getServerDelay' ? 42 : null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('should validate valid JSON config', () async {
      const validConfig = '{"inbounds": [], "outbounds": []}';

      await expectLater(
        v2ray.startV2Ray(
          remark: 'Test',
          config: validConfig,
          proxyOnly: true,
        ),
        completes,
      );
    });

    test('should throw ArgumentError for invalid JSON config', () {
      const invalidConfig = 'invalid json';

      expect(
          () => v2ray.startV2Ray(
                remark: 'Test',
                config: invalidConfig,
                proxyOnly: true,
              ),
          throwsArgumentError);
    });

    test('should validate server delay with valid JSON config', () async {
      const validConfig = '{"inbounds": [], "outbounds": []}';

      await expectLater(
        v2ray.getServerDelay(config: validConfig),
        completion(42),
      );
    });

    test('should throw ArgumentError for server delay with invalid JSON config',
        () {
      const invalidConfig = 'invalid json';

      expect(() => v2ray.getServerDelay(config: invalidConfig),
          throwsArgumentError);
    });
  });

  group('FakeDNS wiring', () {
    // FakeDNS only works when four pieces agree. Declaring the pools while
    // leaving any of the others out produces a config that looks like it
    // enables FakeDNS and silently does not, which is what this guards.
    const vlessUrl =
        'vless://12345678-abcd-1234-abcd-12345678abcd@10.0.0.1:443?type=tcp&security=tls&sni=example.com#FakeDNS';

    Map<String, dynamic> configFor(String url) {
      final parsed = V2ray.parseFromURL(url);
      return jsonDecode(parsed.getFullConfiguration()) as Map<String, dynamic>;
    }

    test('fakedns is the first dns server', () {
      final dns = configFor(vlessUrl)['dns'] as Map<String, dynamic>;
      final servers = dns['servers'] as List;

      expect(servers, isNotEmpty);
      expect(
        servers.first,
        equals('fakedns'),
        reason: 'fakedns must answer first, or real resolvers win and no '
            'fake address is ever issued',
      );
      expect(
        servers.length,
        greaterThan(1),
        reason: 'a real resolver has to remain as the fallback',
      );
    });

    test('dns queries are routed to the dns outbound', () {
      final config = configFor(vlessUrl);
      final routing = config['routing'] as Map<String, dynamic>;
      final rules = routing['rules'] as List;

      final dnsRule = rules.cast<Map<String, dynamic>>().firstWhere(
            (rule) => rule['outboundTag'] == 'dns-out',
            orElse: () => <String, dynamic>{},
          );

      expect(
        dnsRule,
        isNotEmpty,
        reason: 'without this rule nothing reaches the DNS module and the '
            'dns-out outbound is dead weight',
      );
      expect(dnsRule['type'], equals('field'),
          reason: 'xray rejects a rule with no type');
      expect(dnsRule['port'], equals(53));
      expect(dnsRule['inboundTag'], contains('in_proxy'));
    });

    test('the dns outbound the rule points at exists', () {
      final outbounds = (configFor(vlessUrl)['outbounds'] as List)
          .cast<Map<String, dynamic>>();

      final dnsOutbound = outbounds.firstWhere(
        (outbound) => outbound['tag'] == 'dns-out',
        orElse: () => <String, dynamic>{},
      );

      expect(dnsOutbound, isNotEmpty);
      expect(dnsOutbound['protocol'], equals('dns'));
    });

    test('both address pools are declared', () {
      final pools =
          (configFor(vlessUrl)['fakedns'] as List).cast<Map<String, dynamic>>();

      expect(pools, hasLength(2),
          reason: 'a missing IPv6 pool crashes the core on AAAA queries');
      expect(pools.map((pool) => pool['ipPool']), contains('198.18.0.0/16'));
      expect(pools.any((pool) => (pool['ipPool'] as String).contains(':')),
          isTrue);
    });

    test('sniffing maps fake addresses back to domains', () {
      final inbounds =
          (configFor(vlessUrl)['inbounds'] as List).cast<Map<String, dynamic>>();
      final sniffing = inbounds.first['sniffing'] as Map<String, dynamic>;

      expect(sniffing['enabled'], isTrue);
      expect(
        sniffing['destOverride'],
        contains('fakedns'),
        reason: 'without this the proxy receives the fake address rather than '
            'the domain it stands for',
      );
    });

    test('the tunnel address on iOS stays outside the fake pool', () {
      final pools =
          (configFor(vlessUrl)['fakedns'] as List).cast<Map<String, dynamic>>();
      final ipv4Pool = pools
          .map((pool) => pool['ipPool'] as String)
          .firstWhere((pool) => !pool.contains(':'));

      // PacketTunnelProvider assigns 172.19.0.1 to the interface. An address
      // inside the pool could be handed to a domain, so the two must not
      // overlap. This fails loudly if either side is changed alone.
      expect(ipv4Pool, equals('198.18.0.0/16'));
      expect(ipv4Pool.startsWith('172.19.'), isFalse);
    });
  });

  group('Generated config golden', () {
    // ios/core/testdata/generated_config.json is what the Go tests hand to
    // xray-core to confirm the core accepts what this package emits. It is a
    // copy, so it can drift — this fails when it does, and the message says
    // how to refresh it.
    test('matches ios/core/testdata/generated_config.json', () {
      final fixture = File('ios/core/testdata/generated_config.json');
      if (!fixture.existsSync()) {
        fail('missing fixture at ${fixture.path}');
      }

      final generated = jsonDecode(
        VlessURL(
          url: 'vless://12345678-abcd-1234-abcd-12345678abcd@example.com:443'
              '?type=tcp&security=tls&sni=example.com#Golden',
        ).getFullConfiguration(),
      ) as Map<String, dynamic>;
      // The fixture pins the port so it stays stable in review; the Go test
      // substitutes a free one before starting the core.
      (generated['inbounds'] as List).cast<Map<String, dynamic>>().first['port'] =
          1080;

      final recorded =
          jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;

      expect(
        const JsonEncoder.withIndent('  ').convert(generated),
        equals(const JsonEncoder.withIndent('  ').convert(recorded)),
        reason: 'the generated configuration changed. Refresh the fixture so '
            'the Go tests validate what this package actually emits.',
      );
    });
  });
}
