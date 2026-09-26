import 'models.dart';

/// Return null if the issuer/client pair is unknown or ambiguous.
abstract interface class LtiRegistrationStore {
  Future<LtiRegistration?> find(String issuer, {String? clientId});
}

final class MemoryLtiRegistrationStore implements LtiRegistrationStore {
  MemoryLtiRegistrationStore(Iterable<LtiRegistration> registrations)
    : _registrations = List.unmodifiable(registrations) {
    final keys = <(String, String)>{};
    for (final registration in _registrations) {
      if (!keys.add((registration.issuer, registration.clientId))) {
        throw ArgumentError('Duplicate issuer/client registration.');
      }
    }
  }
  final List<LtiRegistration> _registrations;

  @override
  Future<LtiRegistration?> find(String issuer, {String? clientId}) async {
    final matches = _registrations.where(
      (r) => r.issuer == issuer && (clientId == null || r.clientId == clientId),
    );
    return matches.length == 1 ? matches.single : null;
  }
}

/// Short-lived login state. Treat this record as a secret in persistent stores.
final class LtiLoginTransaction {
  const LtiLoginTransaction({
    required this.state,
    required this.nonce,
    required this.browserBinding,
    required this.issuer,
    required this.clientId,
    required this.targetLinkUri,
    required this.createdAt,
    required this.expiresAt,
    this.deploymentId,
  });
  final String state;
  final String nonce;
  final String browserBinding;
  final String issuer;
  final String clientId;
  final String targetLinkUri;
  final String? deploymentId;
  final DateTime createdAt;
  final DateTime expiresAt;
}

/// Implementations MUST atomically match binding/expiry and remove the record.
/// Concurrent consumption must succeed at most once, across all server instances.
abstract interface class LtiTransactionStore {
  /// MUST reject a duplicate state rather than overwrite an existing transaction.
  Future<void> save(LtiLoginTransaction transaction);
  Future<LtiLoginTransaction?> consume({
    required String state,
    required String browserBinding,
    required DateTime now,
  });
}

/// Development store for a single isolate. Use shared storage in production.
final class MemoryLtiTransactionStore implements LtiTransactionStore {
  MemoryLtiTransactionStore({this.capacity = 10000}) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }
  final int capacity;
  final _entries = <String, LtiLoginTransaction>{};

  @override
  Future<void> save(LtiLoginTransaction transaction) async {
    _entries.removeWhere(
      (_, value) => !value.expiresAt.isAfter(transaction.createdAt),
    );
    if (_entries.containsKey(transaction.state) ||
        _entries.length >= capacity) {
      throw StateError('Transaction store is full or state already exists.');
    }
    _entries[transaction.state] = transaction;
  }

  @override
  Future<LtiLoginTransaction?> consume({
    required String state,
    required String browserBinding,
    required DateTime now,
  }) async {
    final entry = _entries[state];
    if (entry == null) return null;
    if (!entry.expiresAt.isAfter(now)) {
      _entries.remove(state);
      return null;
    }
    if (!constantTimeEquals(entry.browserBinding, browserBinding)) return null;
    return _entries.remove(state);
  }
}

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
