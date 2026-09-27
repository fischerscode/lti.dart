import 'dart:convert';

import 'errors.dart';
import 'models.dart';

/// Claim names for LTI Deep Linking requests and responses.
abstract final class LtiDeepLinkingClaims {
  /// Namespace for Deep Linking claim names.
  static const prefix = 'https://purl.imsglobal.org/spec/lti-dl/claim/';

  /// Claim containing the platform's selection capabilities and return URL.
  static const settings = '${prefix}deep_linking_settings';

  /// Response claim containing the selected content item array.
  static const contentItems = '${prefix}content_items';

  /// Opaque platform data echoed unchanged into the signed response.
  static const data = '${prefix}data';

  /// Optional human-readable success message returned to the platform.
  static const message = '${prefix}msg';

  /// Optional diagnostic message intended for the platform's logs.
  static const log = '${prefix}log';

  /// Optional human-readable error returned to the platform.
  static const errorMessage = '${prefix}errormsg';

  /// Optional error detail intended for the platform's logs.
  static const errorLog = '${prefix}errorlog';
}

/// Capabilities supplied in a signed selection request. Unknown types and
/// document targets are retained so extensions can be negotiated explicitly.
final class LtiDeepLinkingSettings {
  /// Parses and snapshots settings from a verified Deep Linking request.
  ///
  /// Requires an HTTPS return URL and string arrays for accepted types and
  /// presentation targets. Throws [LtiException] on malformed settings.
  LtiDeepLinkingSettings.fromJson(Map<String, Object?> json)
    : this._(freezeJson(json) as Map<String, Object?>);

  LtiDeepLinkingSettings._(this.raw)
    : returnUrl = _returnUrl(raw),
      acceptTypes = stringList(raw['accept_types']),
      acceptPresentationDocumentTargets = stringList(
        raw['accept_presentation_document_targets'],
      ),
      acceptMediaTypes = optionalString(raw, 'accept_media_types'),
      acceptMultiple = _boolean(raw, 'accept_multiple') ?? false,
      acceptLineItem = _boolean(raw, 'accept_lineitem'),
      autoCreate = _boolean(raw, 'auto_create') ?? false,
      title = optionalString(raw, 'title'),
      text = optionalString(raw, 'text');

  /// Deeply immutable settings, including unknown extension properties.
  final Map<String, Object?> raw;

  /// HTTPS platform destination for posting the signed selection response.
  final Uri returnUrl;

  /// Immutable list of content item types the platform can accept.
  final List<String> acceptTypes;

  /// Accepted presentation targets, including any negotiated extensions.
  final List<String> acceptPresentationDocumentTargets;

  /// Comma-separated MIME ranges for files, or null when unrestricted.
  final String? acceptMediaTypes;

  /// Whether multiple selected items may be returned; defaults to false.
  final bool acceptMultiple;

  /// Platform hint for line-item acceptance, or null if unspecified.
  /// This hint is exposed to the application and is not a selection rejection rule.
  final bool? acceptLineItem;

  /// Whether the platform requests automatic creation; defaults to false.
  /// This is a hint for the host selection UI, not an automatic action.
  final bool autoCreate;

  /// Optional title suggested by the platform for the selected content.
  final String? title;

  /// Optional descriptive text suggested by the platform.
  final String? text;

  /// Whether opaque return data was supplied, including an explicit null.
  bool get hasData => raw.containsKey('data');

  /// Opaque value to echo unchanged when [hasData] is true; may be null.
  Object? get data => raw['data'];

  static Uri _returnUrl(Map<String, Object?> raw) {
    requiredString(raw, 'deep_link_return_url');
    return optionalHttpsUri(raw, 'deep_link_return_url')!;
  }

  static bool? _boolean(Map<String, Object?> raw, String key) {
    if (!raw.containsKey(key)) return null;
    final value = raw[key];
    if (value is bool) return value;
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Expected a boolean setting.',
    );
  }

  /// Checks [items] against multiplicity, types, presentation and file MIME ranges.
  ///
  /// An empty list represents cancellation and is allowed. Throws [ArgumentError]
  /// for incompatible selections. This does not authorize the user's choice or
  /// enforce application policy; inspect other platform hints in the host UI.
  void validateSelection(List<LtiContentItem> items) {
    if (!acceptMultiple && items.length > 1) {
      throw ArgumentError('The platform accepts at most one item.');
    }
    for (final item in items) {
      if (!acceptTypes.contains(item.type)) {
        throw ArgumentError('The platform does not accept this content type.');
      }
      for (final target in ['window', 'iframe', 'embed']) {
        if (item.toJson().containsKey(target) &&
            !acceptPresentationDocumentTargets.contains(target)) {
          throw ArgumentError(
            'The platform does not accept this presentation target.',
          );
        }
      }
      if (item.type == 'file' && acceptMediaTypes != null) {
        final media = item.mediaType?.toLowerCase();
        // A local hint: mediaType is not a Deep Linking File wire property.
        if (media == null ||
            !acceptMediaTypes!.split(',').any((range) {
              final pattern = range.trim().toLowerCase();
              return pattern == media ||
                  pattern == '*/*' ||
                  (pattern.endsWith('/*') &&
                      media.startsWith(
                        pattern.substring(0, pattern.length - 1),
                      ));
            })) {
          throw ArgumentError('A file must have an accepted media type.');
        }
      }
    }
  }
}

/// Immutable content item. Named constructors cover standard types; [LtiContentItem.fromJson]
/// also supports extension properties and fully-qualified extension type URLs.
/// URLs follow this library's HTTPS-only resource policy.
final class LtiContentItem {
  /// Snapshots and validates a standard or extension content item.
  ///
  /// [mediaType] is a local file MIME hint, not a serialized File property.
  /// Unknown properties are retained; extension types must be HTTPS URLs.
  /// Malformed fields throw [ArgumentError] or [LtiException]; non-JSON data
  /// fails JSON encoding. Embedded HTML is not sanitized by this constructor.
  LtiContentItem.fromJson(Map<String, Object?> json, {this.mediaType})
    : _json = freezeJson(jsonDecode(jsonEncode(json))) as Map<String, Object?> {
    final type = requiredString(_json, 'type');
    if (!const [
      'link',
      'ltiResourceLink',
      'file',
      'html',
      'image',
    ].contains(type)) {
      _url(type);
    }
    for (final key in ['title', 'text']) {
      optionalString(_json, key);
    }
    if (['link', 'file', 'image'].contains(type)) requiredString(_json, 'url');
    if (_json.containsKey('url')) _url(requiredString(_json, 'url'));
    if (type == 'html') {
      if (optionalString(_json, 'html') == null) {
        throw ArgumentError('HTML is required.');
      }
    }
    _dimensions(_json);
    for (final key in ['icon', 'thumbnail']) {
      if (_json.containsKey(key)) {
        final image = jsonObject(_json[key]);
        _url(requiredString(image, 'url'));
        _dimensions(image);
      }
    }
    for (final key in ['iframe', 'window', 'embed']) {
      if (!_json.containsKey(key)) continue;
      if (type != 'link' && type != 'ltiResourceLink') {
        throw ArgumentError('Invalid presentation for this type.');
      }
      final presentation = jsonObject(_json[key]);
      _dimensions(presentation);
      if (key == 'iframe') {
        if (type == 'link') _url(requiredString(presentation, 'src'));
        if (type == 'ltiResourceLink' && presentation.containsKey('src')) {
          throw ArgumentError('LTI iframes cannot override src.');
        }
      } else if (key == 'embed') {
        if (type != 'link' || optionalString(presentation, 'html') == null) {
          throw ArgumentError('Invalid embed HTML.');
        }
      } else {
        optionalString(presentation, 'targetName');
        optionalString(presentation, 'windowFeatures');
      }
    }
    if (_json.containsKey('custom')) {
      if (type != 'ltiResourceLink' ||
          jsonObject(_json['custom']).values.any((v) => v is! String)) {
        throw ArgumentError('Custom values must be LTI strings.');
      }
    }
    if (_json.containsKey('lineItem')) {
      if (type != 'ltiResourceLink') {
        throw ArgumentError('Line items require an LTI resource.');
      }
      final line = jsonObject(_json['lineItem']);
      final maximum = line['scoreMaximum'];
      if (maximum is! num || !maximum.isFinite || maximum <= 0) {
        throw ArgumentError('A positive score maximum is required.');
      }
      for (final field in ['label', 'resourceId', 'tag']) {
        optionalString(line, field);
      }
      if (line.containsKey('gradesReleased') &&
          line['gradesReleased'] is! bool) {
        throw ArgumentError('Invalid gradesReleased.');
      }
    }
    if (_json.containsKey('expiresAt')) _date(_json, 'expiresAt');
    for (final field in ['available', 'submission']) {
      if (!_json.containsKey(field)) continue;
      if (type != 'ltiResourceLink') {
        throw ArgumentError('Time windows require an LTI resource.');
      }
      final period = jsonObject(_json[field]);
      final start = _date(period, 'startDateTime');
      final end = _date(period, 'endDateTime');
      if (start != null && end != null && start.isAfter(end)) {
        throw ArgumentError('Time window ends before it starts.');
      }
    }
  }

  /// Creates a tool resource selection, optionally with gradebook metadata.
  ///
  /// [url] may be omitted for platform-defined resolution. [custom] contains
  /// string values sent on later launches. [properties] supplies extra fields;
  /// explicit constructor fields take precedence. Selection acceptance is checked
  /// when building the response, not here.
  factory LtiContentItem.ltiResourceLink({
    Uri? url,
    String? title,
    String? text,
    Map<String, String> custom = const {},
    LtiDeepLinkingLineItem? lineItem,
    Map<String, Object?> properties = const {},
  }) => LtiContentItem.fromJson({
    ...properties,
    'type': 'ltiResourceLink',
    'url': ?url?.toString(),
    'title': ?title,
    'text': ?text,
    'custom': custom,
    'lineItem': ?lineItem?.toJson(),
  });

  /// Creates an ordinary HTTPS link, without LTI launch authentication.
  ///
  /// [properties] may contain validated presentation hints such as `iframe` or
  /// `window`. Explicit constructor fields override matching properties.
  factory LtiContentItem.link({
    required Uri url,
    String? title,
    String? text,
    Map<String, Object?> properties = const {},
  }) => LtiContentItem.fromJson({
    ...properties,
    'type': 'link',
    'url': url.toString(),
    'title': ?title,
    'text': ?text,
  });

  /// Creates a downloadable HTTPS file selection.
  ///
  /// Supply [mediaType] when the platform restricts accepted MIME types.
  /// [expiresAt] is serialized in UTC. [properties] retains additional fields;
  /// explicit constructor fields take precedence. This does not upload a file.
  factory LtiContentItem.file({
    required Uri url,
    String? title,
    String? text,
    String? mediaType,
    DateTime? expiresAt,
    Map<String, Object?> properties = const {},
  }) => LtiContentItem.fromJson({
    ...properties,
    'type': 'file',
    'url': url.toString(),
    'title': ?title,
    'text': ?text,
    'expiresAt': ?expiresAt?.toUtc().toIso8601String(),
  }, mediaType: mediaType);

  /// Creates an HTML content selection with optional display metadata.
  ///
  /// [html] is carried as supplied and is not sanitized. The host application
  /// must ensure content is appropriate for the destination platform.
  factory LtiContentItem.html({
    required String html,
    String? title,
    String? text,
  }) => LtiContentItem.fromJson({
    'type': 'html',
    'html': html,
    'title': ?title,
    'text': ?text,
  });

  /// Creates an HTTPS image selection with optional pixel dimensions.
  ///
  /// [width] and [height] must be nonnegative when supplied. [properties] adds
  /// extra fields; explicit constructor fields take precedence.
  factory LtiContentItem.image({
    required Uri url,
    String? title,
    String? text,
    int? width,
    int? height,
    Map<String, Object?> properties = const {},
  }) => LtiContentItem.fromJson({
    ...properties,
    'type': 'image',
    'url': url.toString(),
    'title': ?title,
    'text': ?text,
    'width': ?width,
    'height': ?height,
  });

  final Map<String, Object?> _json;

  /// Local file MIME hint used for negotiation; excluded from serialized JSON.
  final String? mediaType;

  /// Standard content type name or fully qualified extension type URL.
  String get type => _json['type']! as String;

  /// Returns the deeply immutable content item payload for a signed response.
  Map<String, Object?> toJson() => _json;

  static void _url(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError('An absolute HTTPS URL is required.');
    }
  }

  static void _dimensions(Map<String, Object?> data) {
    for (final name in ['width', 'height']) {
      if (data.containsKey(name) &&
          (data[name] is! int || (data[name]! as int) < 0)) {
        throw ArgumentError('Dimensions must be nonnegative integers.');
      }
    }
  }

  static DateTime? _date(Map<String, Object?> data, String field) {
    if (!data.containsKey(field)) return null;
    final raw = optionalString(data, field)!;
    final date = DateTime.tryParse(raw);
    if (date == null || !RegExp(r'T.*(?:Z|[+-]\d{2}:\d{2})$').hasMatch(raw)) {
      throw ArgumentError('Expected an ISO 8601 timestamp with timezone.');
    }
    return date;
  }
}

/// Gradebook-column proposal attached to a Deep Linking resource selection.
///
/// This differs from an AGS line item: the platform creates the actual column
/// when accepting the selection, rather than through a service call here.
final class LtiDeepLinkingLineItem {
  /// Creates a column proposal with a positive finite [scoreMaximum].
  ///
  /// Throws [ArgumentError] for an invalid maximum. Optional metadata is
  /// passed to the platform when the containing resource selection is accepted.
  LtiDeepLinkingLineItem({
    required this.scoreMaximum,
    this.label,
    this.resourceId,
    this.tag,
    this.gradesReleased,
  }) {
    if (!scoreMaximum.isFinite || scoreMaximum <= 0) {
      throw ArgumentError('A positive score maximum is required.');
    }
  }

  /// Positive finite maximum points for this gradebook column.
  final num scoreMaximum;

  /// Display label for the gradebook column.
  final String? label;

  /// Optional tool-defined resource identifier shared across related columns.
  final String? resourceId;

  /// Optional tool-defined category or lookup tag for this column.
  final String? tag;

  /// Optional hint indicating whether grades are released to learners.
  final bool? gradesReleased;

  /// Returns the unmodifiable wire representation for this line item.
  Map<String, Object?> toJson() => Map.unmodifiable({
    'scoreMaximum': scoreMaximum,
    'label': ?label,
    'resourceId': ?resourceId,
    'tag': ?tag,
    'gradesReleased': ?gradesReleased,
  });
}

/// Browser return message. Use the uppercase JWT form field, never a GET query.
final class LtiDeepLinkingResponse {
  /// Wraps a signed [jwt] and its HTTPS [returnUrl].
  ///
  /// Throws [ArgumentError] for an unsafe return URL. This constructor does not
  /// verify the JWT; use the tool response builder to produce a signed selection.
  LtiDeepLinkingResponse({required this.returnUrl, required this.jwt}) {
    LtiContentItem._url(returnUrl.toString());
  }

  /// HTTPS platform endpoint that must receive the browser form POST.
  final Uri returnUrl;

  /// Signed response credential; never place it in logs or a GET query.
  final String jwt;

  /// Immutable form fields with uppercase `JWT`, as required by Deep Linking.
  Map<String, String> get formFields => Map.unmodifiable({'JWT': jwt});
}
