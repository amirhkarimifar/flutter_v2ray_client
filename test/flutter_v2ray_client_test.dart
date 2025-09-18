import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';

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

    setUp(() {
      v2ray = V2ray(onStatusChanged: (_) {});
    });

    test('should validate valid JSON config', () {
      const validConfig = '{"inbounds": [], "outbounds": []}';

      expect(
          () => v2ray.startV2Ray(
                remark: 'Test',
                config: validConfig,
                proxyOnly: true,
              ),
          returnsNormally);
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

    test('should validate server delay with valid JSON config', () {
      const validConfig = '{"inbounds": [], "outbounds": []}';

      expect(() => v2ray.getServerDelay(config: validConfig), returnsNormally);
    });

    test('should throw ArgumentError for server delay with invalid JSON config',
        () {
      const invalidConfig = 'invalid json';

      expect(() => v2ray.getServerDelay(config: invalidConfig),
          throwsArgumentError);
    });
  });
}
