// Concurrent echo benchmark — opens C connections simultaneously, each does M round-trips.
// Run: dart lib/bench_echo_concurrent.dart <host> <port> <conns> <msgs_per_conn>
//
// ignore_for_file: unawaited_futures

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

const kPayload = 1024; // bytes — large enough to stress memcpy path

typedef ConnResult = ({int errors, int completed});
typedef BatchResult = ({int errors, int completed});

Future<ConnResult> runConn(String host, int port, int msgs) async {
  late Socket sock;
  try {
    sock = await Socket.connect(host, port);
  } catch (_) {
    return (errors: 1, completed: 0);
  }
  sock.setOption(SocketOption.tcpNoDelay, true);

  final payload = Uint8List(kPayload)..fillRange(0, kPayload, 0x41);
  int received = 0;
  int errors = 0;
  final done = Completer<void>();

  sock.listen(
    (data) {
      received += data.length;
      if (received >= kPayload * msgs && !done.isCompleted) done.complete();
    },
    onDone: () { if (!done.isCompleted) done.complete(); },
    onError: (_) { errors++; if (!done.isCompleted) done.complete(); },
  );

  for (int m = 0; m < msgs; m++) sock.add(payload);
  await sock.flush();
  await done.future;
  await sock.close();

  final completed = (received ~/ kPayload).clamp(0, msgs) as int;
  return (
    errors: errors + (received < kPayload * msgs ? 1 : 0),
    completed: completed,
  );
}

Future<BatchResult> runBatch(String host, int port, int conns, int msgs) async {
  final futures = List.generate(conns, (_) => runConn(host, port, msgs));
  final results = await Future.wait(futures);
  final errors = results.fold<int>(0, (a, b) => a + b.errors);
  final completed = results.fold<int>(0, (a, b) => a + b.completed);
  return (errors: errors, completed: completed);
}

Future<void> main(List<String> args) async {
  final host  = args.isNotEmpty ? args[0]            : '127.0.0.1';
  final port  = args.length > 1 ? int.parse(args[1]) : 9090;
  final conns = args.length > 2 ? int.parse(args[2]) : 200;
  final msgs  = args.length > 3 ? int.parse(args[3]) : 100;
  final total = conns * msgs;

  print('Concurrent benchmark: $conns conns × $msgs msgs × ${kPayload}B = ${total} round-trips');
  print('Payload: ${kPayload}B  Total data: ${total * kPayload ~/ 1024}KB  Server: $host:$port');

  // Warmup
  final warmup = await runBatch(host, port, 10, 5);
  if (warmup.errors > 0) {
    print('Warmup errors: ${warmup.errors} (completed ${warmup.completed}/50)');
  }

  // 3 runs
  var timedErrors = 0;
  for (int run = 1; run <= 3; run++) {
    final sw = Stopwatch()..start();
    final result = await runBatch(host, port, conns, msgs);
    sw.stop();
    final ms = sw.elapsedMilliseconds == 0 ? 1 : sw.elapsedMilliseconds;
    final rps = (result.completed * 1000 / ms).round();
    final mbps = (result.completed * kPayload * 2 / ms / 1024).round(); // ×2 for rx+tx
    if (result.errors > 0) {
      timedErrors += result.errors;
      print('  run $run: ${ms}ms  =>  $rps req/s  ~${mbps} MB/s  (errors: ${result.errors}, completed: ${result.completed}/$total)');
    } else {
      print('  run $run: ${ms}ms  =>  $rps req/s  ~${mbps} MB/s  (completed: ${result.completed}/$total)');
    }
  }

  if (timedErrors > 0) {
    stderr.writeln('Benchmark invalid: timed runs had $timedErrors errors.');
    exitCode = 2;
  }
}
