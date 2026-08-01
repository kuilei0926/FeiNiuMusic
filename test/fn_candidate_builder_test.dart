import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_models.dart';

FnConnectionParams _params() {
  return FnConnectionParams(
    internalIPv4s: ['192.168.1.10'],
    publicIPv4s: ['1.2.3.4'],
    publicIPv6s: ['2409::1'],
    httpsPort: 5667,
    httpPort: 5666,
    relayAddresses: ['myid.5ddd.com:443'],
  );
}

void main() {
  test('default order builds internal → v6 → v4 → relay', () {
    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: _params(),
      order: kDefaultConnectionOrder,
    );

    final addresses = specs.map((s) => s.address).toList();
    expect(addresses, [
      // 内网 IP：HTTP 优先（避开自签名证书校验），HTTPS 兜底
      'http://192.168.1.10:5666',
      'https://192.168.1.10:5667',
      // 公网 IPv6：HTTP 优先 → HTTPS
      'http://[2409::1]:5666',
      'https://[2409::1]:5667',
      // 公网 IPv4：HTTP 优先 → HTTPS
      'http://1.2.3.4:5666',
      'https://1.2.3.4:5667',
      // 中继（域名，仅 HTTPS）
      'https://myid.5ddd.com',
    ]);
    expect(specs.last.group, ProbeCandidateGroup.relay);
    expect(specs.last.relayMode, true);
  });

  test('IP groups HTTP first, HTTPS fallback; relay stays HTTPS-only', () {
    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: _params(),
      order: kDefaultConnectionOrder,
    );

    final addresses = specs.map((s) => s.address).toList();
    expect(addresses, [
      // 内网 IP：HTTP 优先 → HTTPS 兜底
      'http://192.168.1.10:5666',
      'https://192.168.1.10:5667',
      // 公网 IPv6：HTTP 优先 → HTTPS
      'http://[2409::1]:5666',
      'https://[2409::1]:5667',
      // 公网 IPv4：HTTP 优先 → HTTPS
      'http://1.2.3.4:5666',
      'https://1.2.3.4:5667',
      // 中继（域名，始终 HTTPS）
      'https://myid.5ddd.com',
    ]);
    // 每个 IP 组都是 HTTP 在前
    for (final group in [ProbeCandidateGroup.internal, ProbeCandidateGroup.publicIPv6, ProbeCandidateGroup.publicIPv4]) {
      final groupSpecs = specs.where((s) => s.group == group).toList();
      expect(groupSpecs.length, 2, reason: '$group 应生成 HTTP + HTTPS 两条');
      expect(groupSpecs[0].address.startsWith('http://'), isTrue,
          reason: '$group 应 HTTP 优先');
      expect(groupSpecs[1].address.startsWith('https://'), isTrue,
          reason: '$group 应 HTTPS 兜底');
    }
    // 中继仅 HTTPS
    final relay = specs.where((s) => s.group == ProbeCandidateGroup.relay).toList();
    expect(relay.length, 1);
    expect(relay.single.address.startsWith('https://'), isTrue);
  });

  test('custom order controls group sequence', () {
    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: _params(),
      order: [ProbeCandidateGroup.relay, ProbeCandidateGroup.internal],
    );

    final groups = specs.map((s) => s.group).toList();
    expect(groups, [
      ProbeCandidateGroup.relay,
      ProbeCandidateGroup.internal,
      ProbeCandidateGroup.internal,
    ]);
  });

  test('empty relay addresses falls back to fnId.5ddd.com', () {
    final params = FnConnectionParams(
      internalIPv4s: const [],
      publicIPv4s: const [],
      publicIPv6s: const [],
      httpsPort: 5667,
      httpPort: 5666,
      relayAddresses: const [],
    );

    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: params,
      order: kDefaultConnectionOrder,
    );

    expect(specs.length, 1);
    expect(specs.single.address, 'https://myid.5ddd.com');
  });
}
