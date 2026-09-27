import 'package:lti/lti.dart';

/// Explicitly enabled, read-only diagnostics. Never displays roster/grade data.
Future<String> serviceReadReport(
  LtiResourceLaunch launch,
  LtiServiceClient Function(LtiResourceLaunch) servicesFor,
) async {
  final lines = <String>[
    'AGS advertised: ${launch.ags != null}',
    'NRPS advertised: ${launch.nrps != null}',
  ];
  final instructor = launch.roles.any(
    (role) =>
        LtiRoles.isStandard(role) &&
        (role == LtiRoles.instructor ||
            role.startsWith('${LtiRoles.membership}/Instructor#')),
  );
  if (launch.user == null || !instructor) {
    lines.add(
      'Service reads skipped: authenticated context instructor required.',
    );
    return lines.join('\n');
  }
  final services = servicesFor(launch);
  Future<void> check(String label, Future<String> Function() run) async {
    try {
      lines.add('$label: ${await run()}');
    } on LtiOAuthException catch (error) {
      lines.add(
        '$label: OAuth ${error.code.name}; HTTP ${error.statusCode ?? 'n/a'}',
      );
    } on LtiServiceException catch (error) {
      lines.add(
        '$label: service ${error.code.name}; HTTP ${error.statusCode ?? 'n/a'}',
      );
    } catch (_) {
      lines.add('$label: internal test error.');
    }
  }

  if (launch.nrps != null) {
    await check('NRPS', () async {
      final page = await services.nrps.memberships(limit: 10);
      return 'OK; first page members=${page.items.length}; next=${page.next != null}';
    });
  }
  if (launch.ags != null) {
    await check('AGS line items', () async {
      if (launch.ags!.lineItems != null) {
        final page = await services.ags.lineItems(limit: 10);
        return 'OK; first page items=${page.items.length}; next=${page.next != null}';
      }
      if (launch.ags!.lineItem != null) {
        await services.ags.getLineItem();
        return 'OK; single line item read';
      }
      return 'SKIPPED; no line item endpoint';
    });
  }
  lines.add('Read-only test. No grades or line items were changed.');
  return lines.join('\n');
}
