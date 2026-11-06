import 'package:flutter_test/flutter_test.dart';

import 'package:lxbox/services/url_mask.dart';

void main() {
  group('maskSecrets', () {
    test('https link keeps scheme and host only', () {
      expect(
        maskSecrets('GET https://sub.example.com/api/v1/abc?token=x failed'),
        'GET https://sub.example.com/*** failed',
      );
    });

    test('quoted Go error link keeps the quotes', () {
      expect(
        maskSecrets('Get "https://sub.example.com/s/abc": EOF'),
        'Get "https://sub.example.com/***": EOF',
      );
    });

    test('http link with an IP host masks the IP too', () {
      expect(
        maskSecrets('fetch http://127.0.0.1:18081/sub refused'),
        'fetch http://***/*** refused',
      );
    });

    test('proxy link is masked whole, scheme stays', () {
      expect(
        maskSecrets(
          'bad link vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?pbk=abc#node',
        ),
        'bad link vless://***',
      );
      expect(maskSecrets('ss://YWVzLTI1Ni1nY206cGFzcw@host:8388'), 'ss://***');
    });

    test('e-mail address is masked', () {
      expect(maskSecrets('contact user.name@example.com now'), 'contact *** now');
    });

    test('UUID is masked', () {
      expect(
        maskSecrets('uuid b831381d-6324-4d53-ad4f-8cda48b30811 rejected'),
        'uuid *** rejected',
      );
    });

    test('44 character base64 key is masked', () {
      expect(
        maskSecrets('private_key: yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='),
        'private_key: ***',
      );
    });

    test('long hex token is masked', () {
      expect(
        maskSecrets('token 0123456789abcdef0123456789abcdef used'),
        'token *** used',
      );
    });

    test('IPv4 and IPv6 addresses are masked, ports stay', () {
      expect(
        maskSecrets('dial tcp 1.2.3.4:443: i/o timeout'),
        'dial tcp ***:443: i/o timeout',
      );
      expect(maskSecrets('dial tcp [2001:db8::1]:443'), 'dial tcp [***]:443');
    });

    test('host names, times and node names stay', () {
      const kept = 'lookup sub.example.com: no such host at 12:34:56 '
          'outbound/vless[⚡ node-name]';
      expect(maskSecrets(kept), kept);
    });
  });

  group('maskNetworkAddresses keeps its Automation behaviour', () {
    test('masks IPs and host names', () {
      expect(
        maskNetworkAddresses('dial tcp 1.2.3.4:443 via sub.example.com'),
        'dial tcp ***:443 via ***',
      );
    });
  });
}
