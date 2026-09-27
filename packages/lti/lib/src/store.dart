import 'models.dart';

/// Return null if the issuer/client pair is unknown or ambiguous.
abstract interface class LtiRegistrationStore {
  /// Finds a trusted registration using exact [issuer] and optional [clientId].
  ///
  /// Returns null for no match or an ambiguous issuer-only lookup. Never select
  /// an arbitrary client when multiple registrations share an issuer.
  Future<LtiRegistration?> find(String issuer, {String? clientId});
}

/// Immutable registration collection with exact issuer/client lookup.
final class MemoryLtiRegistrationStore implements LtiRegistrationStore {
  /// Copies [registrations]; throws [ArgumentError] for duplicate issuer/client pairs.
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
  /// Creates the secret transaction record persisted before redirecting.
  ///
  /// The caller supplies random, unpredictable state, nonce and browser binding.
  /// Production stores must protect these values at rest and expire the record.
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

  /// Unique correlation key; saving a duplicate must not overwrite a record.
  final String state;

  /// Expected nonce in the platform's signed ID token.
  final String nonce;

  /// Secret expected from the initiating browser's protected storage.
  final String browserBinding;

  /// Trusted issuer selected when this login was initiated.
  final String issuer;

  /// Trusted client identifier selected when this login was initiated.
  final String clientId;

  /// Exact allowlisted resource URL selected during login initiation.
  final String targetLinkUri;

  /// Optional deployment hint to also enforce when validating the token.
  final String? deploymentId;

  /// Transaction creation time used when applying retention limits.
  final DateTime createdAt;

  /// Exclusive expiry deadline; a transaction cannot be used at this time.
  final DateTime expiresAt;
}

/// Implementations MUST atomically match binding/expiry and remove the record.
/// Concurrent consumption must succeed at most once, across all server instances.
abstract interface class LtiTransactionStore {
  /// MUST reject a duplicate state rather than overwrite an existing transaction.
  Future<void> save(LtiLoginTransaction transaction);

  /// Atomically returns and removes a matching, unexpired transaction.
  ///
  /// Return null for unknown [state], mismatched [browserBinding], or expiry at
  /// or before [now]. A binding mismatch must not consume a valid transaction.
  /// The check and removal must be atomic across processes so concurrent
  /// callbacks succeed at most once. Never log the supplied secrets.
  Future<LtiLoginTransaction?> consume({
    required String state,
    required String browserBinding,
    required DateTime now,
  });
}

/// Development store for a single isolate. Use shared storage in production.
final class MemoryLtiTransactionStore implements LtiTransactionStore {
  /// Creates a process-local store with positive [capacity].
  ///
  /// Throws [ArgumentError] for nonpositive capacity. Saving a duplicate state
  /// or exceeding capacity throws [StateError]. Entries are lost on restart.
  MemoryLtiTransactionStore({this.capacity = 10000}) {
    if (capacity <= 0) throw ArgumentError.value(capacity, 'capacity');
  }

  /// Maximum retained transactions after pruning expired records on save.
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

/// Compares equal-length strings without returning on a differing character.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
