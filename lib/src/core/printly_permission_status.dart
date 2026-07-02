/// Aggregate result of a Bluetooth permission request, owned by printly.
///
/// Deliberately independent from `permission_handler`'s `PermissionStatus`,
/// so that package's major-version bumps (which have changed the enum shape
/// before) never become a breaking change of printly's public API.
enum PrintlyPermissionStatus {
  /// All requested permissions were granted.
  granted,

  /// At least one permission was denied; the user can be asked again.
  denied,

  /// At least one permission was permanently denied — the OS will not show
  /// the prompt again. Send the user to the app settings.
  permanentlyDenied,

  /// The OS restricts the permission (e.g. parental controls); the user
  /// cannot grant it.
  restricted,

  /// iOS only: access was granted in a limited form.
  limited,

  /// iOS only: provisional (quiet) authorization.
  provisional;

  /// Convenience flag: `true` only for [granted].
  bool get isGranted => this == PrintlyPermissionStatus.granted;
}
