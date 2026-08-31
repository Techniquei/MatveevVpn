# Changelog

## 1.0.3

- Added native node selection from the saved subscription.
- Node changes are validated and applied without Terminal or an administrator
  password.

## 1.0.2

- Changed traffic lines to a step graph so peaks stay vertical instead of
  leaning between samples.
- Made upload traffic a distinct pink line matching its speed label.

## 1.0.1

- Documented the domain rules commonly needed for YouTube.
- The app now detects completed setup automatically when it becomes active.
- Initial service startup now waits for macOS and sing-box readiness instead of
  failing after a fixed three-second delay.

## 1.0.0

- First public release.
- Native English macOS interface.
- Selective VLESS routing by domain suffix and application process name.
- Editable rules with validation and live application.
- Passwordless normal operation after the one-time privileged setup.
- Stable 60-second tunnel traffic graph with explicit byte-per-second labels.
- Embedded uninstall action and clean DMG distribution.
