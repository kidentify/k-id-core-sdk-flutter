import 'package:flutter/widgets.dart';

/// The design tokens every widget draws from; pass only the ones you change.
@immutable
class KidAppearanceVariables {
  const KidAppearanceVariables({
    this.colorPrimary = const Color(0xFF4F46E5),
    this.colorOnPrimary = const Color(0xFFFFFFFF),
    this.colorText = const Color(0xFF111827),
    this.colorTextMuted = const Color(0xFF6B7280),
    this.colorSurface = const Color(0xFFFFFFFF),
    this.colorSurfaceMuted = const Color(0xFFF3F4F6),
    this.colorBorder = const Color(0xFFE5E7EB),
    this.colorDanger = const Color(0xFFDC2626),
    this.fontFamily,
    this.radius = 12,
  });

  final Color colorPrimary;
  final Color colorOnPrimary;
  final Color colorText;
  final Color colorTextMuted;
  final Color colorSurface;
  final Color colorSurfaceMuted;
  final Color colorBorder;
  final Color colorDanger;

  /// Null keeps the app's font.
  final String? fontFamily;
  final double radius;
}

/// One element's style; a field left null keeps the default.
@immutable
class KidElementStyle {
  const KidElementStyle({
    this.foregroundColor,
    this.backgroundColor,
    this.borderColor,
    this.fontSize,
    this.fontWeight,
    this.fontFamily,
    this.padding,
    this.cornerRadius,
  });

  final Color? foregroundColor;
  final Color? backgroundColor;
  final Color? borderColor;
  final double? fontSize;
  final FontWeight? fontWeight;
  final String? fontFamily;
  final EdgeInsetsGeometry? padding;
  final double? cornerRadius;

  KidElementStyle _over(KidElementStyle base) => KidElementStyle(
        foregroundColor: foregroundColor ?? base.foregroundColor,
        backgroundColor: backgroundColor ?? base.backgroundColor,
        borderColor: borderColor ?? base.borderColor,
        fontSize: fontSize ?? base.fontSize,
        fontWeight: fontWeight ?? base.fontWeight,
        fontFamily: fontFamily ?? base.fontFamily,
        padding: padding ?? base.padding,
        cornerRadius: cornerRadius ?? base.cornerRadius,
      );
}

/// An element `KidAppearance.elements` can style.
enum KidElementName {
  card,
  title,
  label,
  input,
  button,
  muted,
  danger,
  row,
  pill,
  pillAsk,
  pillAdded,
  askForm,
  controlColumn,
  verifyAge,
  selectJurisdiction,
  collectAge,
  askAnAdult,
  settings,
}

/// The widgets' look: [variables] are the tokens, [elements] override one element each and beat every default.
@immutable
class KidAppearance {
  const KidAppearance({this.variables = const KidAppearanceVariables(), this.elements = const {}});

  final KidAppearanceVariables variables;
  final Map<KidElementName, KidElementStyle> elements;
}

KidElementStyle _font(KidAppearanceVariables v, double size, [FontWeight weight = FontWeight.w400]) =>
    KidElementStyle(fontSize: size, fontWeight: weight, fontFamily: v.fontFamily);

KidElementStyle _defaultStyle(KidElementName key, KidAppearanceVariables v) => switch (key) {
      KidElementName.card => KidElementStyle(
          foregroundColor: v.colorText,
          backgroundColor: v.colorSurface,
          borderColor: v.colorBorder,
          padding: const EdgeInsets.all(20),
          cornerRadius: v.radius,
        )._over(_font(v, 16)),
      KidElementName.title => _font(v, 16, FontWeight.w600),
      KidElementName.label => _font(v, 14, FontWeight.w600),
      KidElementName.input => KidElementStyle(
          borderColor: v.colorBorder,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          cornerRadius: v.radius / 2,
        ),
      KidElementName.button => KidElementStyle(
          foregroundColor: v.colorOnPrimary,
          backgroundColor: v.colorPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          cornerRadius: v.radius / 2,
        )._over(_font(v, 16, FontWeight.w600)),
      KidElementName.muted => KidElementStyle(foregroundColor: v.colorTextMuted)._over(_font(v, 14)),
      KidElementName.danger => KidElementStyle(foregroundColor: v.colorDanger)._over(_font(v, 14)),
      KidElementName.pill => const KidElementStyle(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          cornerRadius: 999,
        )._over(_font(v, 13, FontWeight.w600)),
      KidElementName.pillAsk => KidElementStyle(foregroundColor: v.colorText, borderColor: v.colorBorder),
      KidElementName.pillAdded => KidElementStyle(
          foregroundColor: v.colorOnPrimary,
          backgroundColor: v.colorPrimary,
          borderColor: v.colorPrimary,
        ),
      _ => const KidElementStyle(),
    };

/// The style for [keys], later keys over earlier ones, every override over every default.
KidElementStyle resolveElementStyle(KidAppearance appearance, List<KidElementName> keys) {
  var style = const KidElementStyle();
  for (final key in keys) {
    style = _defaultStyle(key, appearance.variables)._over(style);
  }
  for (final key in keys) {
    style = appearance.elements[key]?._over(style) ?? style;
  }
  return style;
}

/// Draws one element: its box, and the text style its children inherit.
class KidElement extends StatelessWidget {
  const KidElement({super.key, required this.appearance, required this.keys, required this.child});

  final KidAppearance appearance;
  final List<KidElementName> keys;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = resolveElementStyle(appearance, keys);
    final radius = BorderRadius.circular(style.cornerRadius ?? 0);
    final border = style.borderColor;
    final padding = style.padding;
    Widget content = DefaultTextStyle.merge(
      style: TextStyle(
        color: style.foregroundColor,
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        fontFamily: style.fontFamily,
      ),
      child: child,
    );
    if (padding != null) content = Padding(padding: padding, child: content);
    if (style.backgroundColor == null && border == null) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.backgroundColor,
        borderRadius: radius,
        border: border == null ? null : Border.all(color: border),
      ),
      child: content,
    );
  }
}
