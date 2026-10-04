/// Temporary DNS diagnostic.
///
/// Runs two probes against the same host in the same process: `dart:io`'s own
/// resolver, then Android's native `InetAddress.getAllByName` through a
/// MethodChannel. Comparing the two separates a broken Dart resolution path
/// from a broken process-level network binding. Debug-only.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Supabase host, spelled out so the probe does not depend on config
/// parsing. Must stay identical to the host of `SUPABASE_URL`.
const String _diagnosticHost = 'hbvjpawnszzbcjmbkuf.supabase.co';

/// Implemented by `MainActivity`; returns the native resolver's answer.
const MethodChannel _dnsChannel = MethodChannel('com.tango.kyc/dns_test');

/// Runs both probes in order and logs each outcome.
Future<void> runDnsDiagnostic() async {
  if (!kDebugMode) return;

  await _runDartProbe();
  debugPrint('');
  await _runJavaProbe();
  debugPrint('');
  await _runAndroidNetworkProbe();
}

Future<void> _runDartProbe() async {
  debugPrint('[dns-test] START dart host=$_diagnosticHost');
  var outcome = 'ERROR';
  try {
    final addresses = await InternetAddress.lookup(_diagnosticHost);
    debugPrint('[dns-test] SUCCESS count=${addresses.length}');
    for (final address in addresses) {
      debugPrint('[dns-test] address=${address.address}');
      debugPrint('[dns-test] type=${address.type.name}');
    }
    if (addresses.isEmpty) {
      debugPrint('[dns-test] WARNING empty address list');
    } else {
      outcome = 'SUCCESS';
    }
  } catch (error) {
    debugPrint('[dns-test] ERROR');
    debugPrint('[dns-test] runtimeType=${error.runtimeType}');
    debugPrint('[dns-test] error=$error');
  }
  debugPrint('[dns-test] RESULT dart=$outcome');
}

Future<void> _runJavaProbe() async {
  debugPrint('[java-dns] START host=$_diagnosticHost');
  var outcome = 'ERROR';
  try {
    final raw = await _dnsChannel.invokeMethod<Object?>('lookup', {
      'host': _diagnosticHost,
    });
    final entries = raw is List ? raw : const <Object?>[];
    debugPrint('[java-dns] SUCCESS count=${entries.length}');
    for (final entry in entries) {
      final record = entry is Map ? entry : const <Object?, Object?>{};
      debugPrint('[java-dns] address=${record['address']}');
      debugPrint('[java-dns] type=${record['type']}');
    }
    if (entries.isEmpty) {
      debugPrint('[java-dns] WARNING empty address list');
    } else {
      outcome = 'SUCCESS';
    }
  } on PlatformException catch (error) {
    debugPrint('[java-dns] ERROR');
    debugPrint('[java-dns] runtimeType=${error.runtimeType}');
    debugPrint('[java-dns] code=${error.code}');
    debugPrint('[java-dns] error=${error.message}');
    if (error.details != null) {
      debugPrint('[java-dns] details=${error.details}');
    }
  } catch (error) {
    debugPrint('[java-dns] ERROR');
    debugPrint('[java-dns] runtimeType=${error.runtimeType}');
    debugPrint('[java-dns] error=$error');
  }
  debugPrint('[java-dns] RESULT java=$outcome');
}

/// Reports what Android's `ConnectivityManager` says about the app's active
/// network, then resolves the host bound explicitly to that `Network`. This
/// separates "the network is unusable" from "the default resolver is broken".
Future<void> _runAndroidNetworkProbe() async {
  debugPrint('[android-net] START host=$_diagnosticHost');
  try {
    final raw = await _dnsChannel.invokeMethod<Object?>('networkDiagnostic', {
      'host': _diagnosticHost,
    });
    final report = raw is Map ? raw : const <Object?, Object?>{};

    debugPrint('[android-net] ACTIVE_NETWORK=${report['activeNetwork']}');
    debugPrint('[android-net] NETWORK_HANDLE=${report['networkHandle']}');

    final capabilities = report['capabilities'];
    if (capabilities is Map) {
      debugPrint(
        '[android-net] CAPABILITIES='
        'INTERNET:${capabilities['internet']} '
        'VALIDATED:${capabilities['validated']} '
        'NOT_RESTRICTED:${capabilities['notRestricted']}',
      );
    } else {
      debugPrint('[android-net] CAPABILITIES=null');
    }

    final transports = report['transports'];
    debugPrint(
      '[android-net] TRANSPORT='
      '${transports is List ? transports.join(',') : 'unknown'}',
    );

    final linkProperties = report['linkProperties'];
    if (linkProperties is Map) {
      debugPrint(
        '[android-net] LINK_PROPERTIES='
        'iface:${linkProperties['interfaceName']} '
        'mtu:${linkProperties['mtu']} '
        'domains:${linkProperties['domains']} '
        'privateDns:${linkProperties['privateDnsServerName']}',
      );
    } else {
      debugPrint('[android-net] LINK_PROPERTIES=null');
    }

    final dnsServers = report['dnsServers'];
    debugPrint(
      '[android-net] DNS_SERVERS='
      '${dnsServers is List ? dnsServers.join(',') : 'unknown'}',
    );

    final routes = report['routes'];
    if (routes is List && routes.isNotEmpty) {
      for (final route in routes) {
        debugPrint('[android-net] ROUTES=$route');
      }
    } else {
      debugPrint('[android-net] ROUTES=none');
    }

    final networkDns = report['networkDns'];
    final outcome = networkDns is Map ? networkDns['outcome'] : 'ERROR';
    final detail = networkDns is Map ? networkDns['detail'] : 'missing payload';
    debugPrint('[android-net] NETWORK_DNS=$outcome detail=$detail');
  } on PlatformException catch (error) {
    debugPrint('[android-net] ERROR code=${error.code} message=${error.message}');
    debugPrint('[android-net] NETWORK_DNS=ERROR detail=${error.details ?? error.message}');
  } catch (error) {
    debugPrint('[android-net] ERROR runtimeType=${error.runtimeType} error=$error');
    debugPrint('[android-net] NETWORK_DNS=ERROR detail=$error');
  }
  debugPrint('[android-net] RESULT done');
}
