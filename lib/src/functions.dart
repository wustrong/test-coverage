// Copyright (c) 2018, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';
import 'package:coverage/coverage.dart' as coverage;
import 'package:glob/glob.dart';
import 'package:lcov_dart/lcov_dart.dart';
import 'package:path/path.dart' as path;

final _sep = path.separator;

List<File> findTestFiles(Directory packageRoot, {Glob? excludeGlob}) {
  final testsPath = path.join(packageRoot.absolute.path, 'test');
  final testsRoot = Directory(testsPath);
  final contents = testsRoot.listSync(recursive: true);
  final result = <File>[];
  for (final item in contents) {
    if (item is! File) continue;
    if (!item.path.endsWith('_test.dart')) continue;
    final relativePath = item.path.substring(packageRoot.path.length + 1);
    if (excludeGlob != null && excludeGlob.matches(relativePath)) {
      continue;
    }
    result.add(item);
  }
  return result;
}

class TestFileInfo {
  final File testFile;
  final String alias;
  final String import;

  TestFileInfo._(this.testFile, this.alias, this.import);

  factory TestFileInfo.forFile(File testFile) {
    final parts = testFile.absolute.path.split(_sep).toList();
    var relative = <String>[];
    while (parts.last != 'test') {
      relative.add(parts.last);
      parts.removeLast();
    }
    relative = relative.reversed.toList();
    final alias = relative.join('_').replaceFirst('.dart', '');
    final importPath = relative.join('/');
    final import = "import '$importPath' as $alias;";
    return TestFileInfo._(testFile, alias, import);
  }
}

void generateMainScript(Directory packageRoot, List<File> testFiles) {
  final imports = <String>[];
  final mainBody = <String>[];

  for (final test in testFiles) {
    final info = TestFileInfo.forFile(test);
    imports.add(info.import);
    mainBody.add('  ${info.alias}.main();');
  }
  imports.sort();

  final buffer = StringBuffer()
    ..writeln('// Auto-generated by test_coverage. Do not edit by hand.')
    ..writeln('// Consider adding this file to your .gitignore.')
    ..writeln();
  imports.forEach(buffer.writeln);
  buffer
    ..writeln()
    ..writeln('void main() {');
  mainBody.forEach(buffer.writeln);
  buffer.writeln('}');
  File(
    path.join(packageRoot.path, 'test', '.test_coverage.dart'),
  ).writeAsStringSync(buffer.toString());
}

Future<void> runTestsAndCollect(String packageRoot, String port,
    {bool printOutput = false}) async {
  final script = path.join(packageRoot, 'test', '.test_coverage.dart');
  final dartArgs = [
    '--pause-isolates-on-exit',
    '--enable_asserts',
    '--enable-vm-service=$port',
    script
  ];
  final process =
      await Process.start('dart', dartArgs, workingDirectory: packageRoot);
  final serviceUriCompleter = Completer<Uri>();
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    if (printOutput) print(line);
    if (serviceUriCompleter.isCompleted) return;
    final uri = _extractObservatoryUri(line);
    if (uri != null) {
      serviceUriCompleter.complete(uri);
    } else {
      serviceUriCompleter.completeError(line);
    }
  });

  final serviceUri = await serviceUriCompleter.future.catchError((error) {
    process.kill(ProcessSignal.sigkill);
  });

  if (serviceUri == null) {
    throw StateError('Could not run tests with Observatory enabled. '
        'Try setting a different port with --port option.');
  }

  Logger logger;
  Progress progress;
  logger = Logger.standard();
  progress = logger.progress('please wait ...');

  Map<String, Map<int, int>> hitmap;
  try {
    final data = await coverage.collect(serviceUri, true, true, false, {},
        timeout: Duration(milliseconds: 15 * 60 * 1000));
    hitmap = await coverage.createHitmap(data['coverage']);
    await process.stderr.drain<List<int>?>();
    progress.finish();
  } catch (e, s) {
    progress.finish();
    throw 'Tests timeout: there are some problems with the unit test code, \nerror: $e, \nstacktrace:$s';
  }

  final exitStatus = await process.exitCode;
  if (exitStatus != 0) {
    throw 'Tests failed with exit code $exitStatus';
  }
  final resolver = coverage.Resolver(
    packagesPath: path.join(packageRoot, '.packages'),
  );
  final lcov = coverage.LcovFormatter(
    resolver,
    reportOn: ['lib${path.separator}'],
    basePath: packageRoot,
  );
  final coverageData = await lcov.format(hitmap);
  final coveragePath = path.join(packageRoot, 'coverage');
  final coverageDir = Directory(coveragePath);
  if (!coverageDir.existsSync()) {
    coverageDir.createSync();
  }
  File(path.join(coveragePath, 'lcov.info')).writeAsStringSync(coverageData);
}

// copied from `coverage` package
Uri? _extractObservatoryUri(String str) {
  const kObservatoryListening = 'Observatory listening on ';
  final msgPos = str.indexOf(kObservatoryListening);
  if (msgPos == -1) return null;
  final startPos = msgPos + kObservatoryListening.length;
  final endPos = str.indexOf(RegExp(r'(\s|$)'), startPos);
  try {
    return Uri.parse(str.substring(startPos, endPos));
  } on FormatException {
    return null;
  }
}

double calculateLineCoverage(File lcovReport) {
  final report = Report.fromCoverage(lcovReport.readAsStringSync());
  var totalLines = 0;
  var hitLines = 0;
  for (final rec in report.records) {
    if (rec == null || rec.lines == null) {
      continue;
    }
    for (final line in rec.lines!.data) {
      totalLines++;
      hitLines += (line.executionCount > 0) ? 1 : 0;
    }
  }
  return hitLines / totalLines;
}

void generateBadge(Directory packageRoot, double lineCoverage) {
  const leftWidth = 59;
  final value = '${(lineCoverage * 100).floor()}%';
  final color = _color(lineCoverage);
  final metrics = _BadgeMetrics.forPercentage(lineCoverage);
  final rightWidth = metrics.width - leftWidth;
  final content = _kBadgeTemplate
      .replaceAll('{width}', metrics.width.toString())
      .replaceAll('{rightWidth}', rightWidth.toString())
      .replaceAll('{rightX}', metrics.rightX.toString())
      .replaceAll('{rightLength}', metrics.rightLength.toString())
      .replaceAll('{color}', color.toString())
      .replaceAll('{value}', value.toString());
  File(path.join(packageRoot.path, 'coverage_badge.svg'))
      .writeAsStringSync(content);
}

class _BadgeMetrics {
  final int width;
  final int rightX;
  final int rightLength;

  _BadgeMetrics(
      {required this.width, required this.rightX, required this.rightLength});

  factory _BadgeMetrics.forPercentage(double value) {
    final pct = (value * 100).floor();
    if (pct.toString().length == 1) {
      return _BadgeMetrics(
        width: 88,
        rightX: 725,
        rightLength: 190,
      );
    } else if (pct.toString().length == 2) {
      return _BadgeMetrics(
        width: 94,
        rightX: 755,
        rightLength: 250,
      );
    } else {
      return _BadgeMetrics(
        width: 102,
        rightX: 795,
        rightLength: 330,
      );
    }
  }
}

String _color(double percentage) {
  final map = {
    0.0: _Color(0xE0, 0x5D, 0x44),
    0.5: _Color(0xE0, 0x5D, 0x44),
    0.6: _Color(0xDF, 0xB3, 0x17),
    0.9: _Color(0x97, 0xCA, 0x00),
    1.0: _Color(0x44, 0xCC, 0x11),
  };
  var lower = 0.0;
  var upper = 1.0;
  for (final key in map.keys) {
    if (percentage <= key) {
      upper = key;
      break;
    }
    if (key <= 1.0) lower = key;
  }

  final lowerColor = map[lower]!;
  final upperColor = map[upper]!;
  final range = upper - lower;
  final rangePct = (percentage - lower) / range;
  final pctLower = 1 - rangePct;
  final pctUpper = rangePct;
  final r = (lowerColor.r * pctLower + upperColor.r * pctUpper).floor();
  final g = (lowerColor.g * pctLower + upperColor.g * pctUpper).floor();
  final b = (lowerColor.b * pctLower + upperColor.b * pctUpper).floor();
  final color = _Color(r, g, b);
  return color.toString();
}

class _Color {
  final int r, g, b;

  _Color(this.r, this.g, this.b);

  @override
  String toString() =>
      '#${((1 << 24) + (r << 16) + (g << 8) + b).toRadixString(16).substring(1)}';
}

const _kBadgeTemplate = '''
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{width}" height="20">
  <linearGradient id="b" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="a">
    <rect width="{width}" height="20" rx="3" fill="#fff"/>
  </clipPath>
  <g clip-path="url(#a)">
    <path fill="#555" d="M0 0h59v20H0z"/>
    <path fill="{color}" d="M59 0h{rightWidth}v20H59z"/>
    <path fill="url(#b)" d="M0 0h{width}v20H0z"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="110">
    <text x="305" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="490">coverage</text>
    <text x="305" y="140" transform="scale(.1)" textLength="490">coverage</text>
    <text x="{rightX}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="{rightLength}">{value}</text>
    <text x="{rightX}" y="140" transform="scale(.1)" textLength="{rightLength}">{value}</text>
  </g>
</svg>
''';
