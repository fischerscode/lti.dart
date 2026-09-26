import 'dart:convert';

import 'errors.dart';
import 'models.dart';

abstract final class LtiDeepLinkingClaims {
  static const prefix = 'https://purl.imsglobal.org/spec/lti-dl/claim/';
  static const settings = '${prefix}deep_linking_settings';
  static const contentItems = '${prefix}content_items';
  static const data = '${prefix}data';
  static const message = '${prefix}msg';
  static const log = '${prefix}log';
  static const errorMessage = '${prefix}errormsg';
  static const errorLog = '${prefix}errorlog';
}

/// Capabilities supplied in a signed selection request. Unknown types and
/// document targets are retained so extensions can be negotiated explicitly.
final class LtiDeepLinkingSettings {
  LtiDeepLinkingSettings.fromJson(Map<String, Object?> json)
    : raw = freezeJson(json) as Map<String, Object?> {
    requiredString(raw, 'deep_link_return_url');
    returnUrl = optionalHttpsUri(raw, 'deep_link_return_url')!;
    acceptTypes = stringList(raw['accept_types']);
    acceptPresentationDocumentTargets = stringList(
      raw['accept_presentation_document_targets'],
    );
    acceptMediaTypes = optionalString(raw, 'accept_media_types');
    acceptMultiple = _boolean('accept_multiple') ?? false;
    acceptLineItem = _boolean('accept_lineitem');
    autoCreate = _boolean('auto_create') ?? false;
    title = optionalString(raw, 'title');
    text = optionalString(raw, 'text');
  }
  final Map<String, Object?> raw;
  late final Uri returnUrl;
  late final List<String> acceptTypes;
  late final List<String> acceptPresentationDocumentTargets;
  late final String? acceptMediaTypes;
  late final bool acceptMultiple;
  late final bool? acceptLineItem;
  late final bool autoCreate;
  late final String? title;
  late final String? text;
  bool get hasData => raw.containsKey('data');
  Object? get data => raw['data'];

  bool? _boolean(String key) {
    if (!raw.containsKey(key)) return null;
    final value = raw[key];
    if (value is bool) return value;
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Expected a boolean setting.',
    );
  }

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

/// Immutable content item. Named constructors cover standard types; [fromJson]
/// also supports extension properties and fully-qualified extension type URLs.
/// URLs follow this library's HTTPS-only resource policy.
final class LtiContentItem {
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
  final String? mediaType;
  String get type => _json['type']! as String;
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

final class LtiDeepLinkingLineItem {
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
  final num scoreMaximum;
  final String? label;
  final String? resourceId;
  final String? tag;
  final bool? gradesReleased;
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
  LtiDeepLinkingResponse({required this.returnUrl, required this.jwt}) {
    LtiContentItem._url(returnUrl.toString());
  }
  final Uri returnUrl;
  final String jwt;
  Map<String, String> get formFields => Map.unmodifiable({'JWT': jwt});
}
