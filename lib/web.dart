import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:s5/s5.dart';

class WebArchiver {
  final httpClient = http.Client();

  final S5 s5;
  WebArchiver(this.s5);

  final protocols = {'http', 'https'};

  Future<void> init() async {
    final dir = await s5.fs.listDirectoryRecursive(
      'archive/web',
    );
    if (dir != null) {
      for (final file in dir.files.entries) {
        final i = file.key.indexOf('/:');
        final start = file.key.substring(0, i).split('/').reversed.join('.');
        final uri = 'https://$start${file.key.substring(i + 2)}';
        _alreadyArchivedURLs.add(Uri.parse(uri));
      }
    }
  }

  Future<String> archive(String uri, {int maxDepth = 1}) async {
    return await archiveURL(
      Uri.parse(uri),
      remainingDepth: maxDepth,
      ignoreAlreadyArchivedURLs: true,
    );
  }

  final _alreadyArchivedURLs = <Uri>{};

  Future<String> archiveURL(
    Uri url, {
    required int remainingDepth,
    bool ignoreAlreadyArchivedURLs = false,
  }) async {
    if (url.host == 'web.archive.org') return '';
    if (url.isScheme('mailto')) return '';
    url = url.removeFragment();
    if (!ignoreAlreadyArchivedURLs) {
      if (_alreadyArchivedURLs.contains(url)) return '';
    }
    if (remainingDepth < 0) return '';
    print('archive $url');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final http.Response res;
    try {
      final request = http.Request('GET', url);
      request.headers['accept'] = '*/*';
      request.followRedirects = false;
      final streamedRes = await httpClient.send(
        request,
      );
      res = await http.Response.fromStream(streamedRes);
    } catch (e, st) {
      print(e);
      print(st);
      return '';
    }
    // TODO Handle big files
    if (res.bodyBytes.length > (32 * 1000 * 1000)) return '';
    final blob = await s5.api.uploadBlob(res.bodyBytes);
    final fileVersion = FileVersion(ts: ts, plaintextCID: blob, ext: {
      'http': {
        'headers': res.headers,
        'statusCode': res.statusCode,
      }
    });

    final path = <String>[
      'archive',
      'web',
      ...url.host.split('.').reversed,
      ':', // TODO Use one of ~ : @ * + =
      ...url.pathSegments,
    ];
    if (url.hasQuery) {
      // TODO Does replacing all &amp; make sense here?
      path.last = '${path.last}?${url.query}'.replaceAll('&amp;', '&');
    }

    final dir = path.sublist(0, path.length - 1).join('/');

    await s5.fs.createDirectoryRecursive(
      dir,
    );

    await s5.fs.createOrUpdateFile(
      directoryPath: dir,
      fileName: path.last,
      fileVersion: fileVersion,
      mediaType: res.headers['content-type']?.toLowerCase().replaceFirst(
            '; charset=utf-8',
            '',
          ),
    );

    _alreadyArchivedURLs.add(url);

    if (res.statusCode >= 300 && res.statusCode < 400) {
      if (res.headers['location'] != null) {
        final newUri = Uri.parse(res.headers['location']!);
        final resolved = url.resolveUri(newUri);
        await archiveURL(
          resolved,
          remainingDepth: remainingDepth,
        );
      }
    }

    // TODO srcset needs special parsing
    final linkRegex = RegExp(
      '(href|src|poster)="([^"]+)"',
      caseSensitive: false,
    );
    final linkRegex2 = RegExp(
      '(href|src|poster)=\'([^"]+)\'',
      caseSensitive: false,
    );
    // TODO Also check content="https://

    final contentType = res.headers['content-type'] ?? '';

    if (contentType.startsWith('text/html') ||
        contentType.startsWith('text/xhtml')) {
      final html = utf8.decode(res.bodyBytes); // TODO or res.body if not utf8

      for (final match in [
        ...linkRegex.allMatches(html),
        ...linkRegex2.allMatches(html)
      ]) {
        final newUri = Uri.parse(match.group(2)!.trimLeft());
        final resolved = url.resolveUri(newUri);
        await archiveURL(
          resolved,
          remainingDepth: remainingDepth - 1,
        );
      }
    }

    return path.join('/');
  }
}
