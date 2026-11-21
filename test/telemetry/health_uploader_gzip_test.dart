import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/telemetry/health_uploader.dart';

void main() {
  test('gzipFile round-trips the file and hashes the gzipped bytes', () async {
    final dir = await Directory.systemTemp.createTemp('hu_gzip');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/db');
    final raw = List<int>.generate(300000, (i) => (i * 31) % 251);
    await f.writeAsBytes(raw);

    final (gz, digest) = await HealthUploader.gzipFile(f.path);

    expect(gzip.decode(gz), raw);
    expect(digest, sha256.convert(gz).toString());
  });
}
