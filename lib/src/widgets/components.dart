import 'package:flutter/material.dart';

import '../catalog/permissions.dart';
import '../core/settings.dart';
import '../core/types.dart';
import '../core/verify_age.dart';
import '../errors.dart';
import '../models.dart';
import '../strings.dart';
import 'appearance.dart';
import 'jurisdictions.dart';
import 'providers.dart';

part 'settings.dart';

/// An age input the jurisdiction may approve.
enum KidAgeMethod {
  ageSlider('age-slider'),
  dateOfBirth('date-of-birth');

  const KidAgeMethod(this.value);
  final String value;
}

const _defaultAgeMethods = [KidAgeMethod.ageSlider, KidAgeMethod.dateOfBirth];
const _maxSliderAge = 35;

final _email = RegExp(
  r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$",
);

bool _isValidEmail(String email) => _email.hasMatch(email);

String _isoDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

// The widgets use Material inputs, so an app without Material localizations gets the English defaults.
Widget _withMaterial(BuildContext context, Widget child) {
  final direction = KidCoreProvider.of(context).direction;
  return _withMaterialLocalizations(
    context,
    Material(
      type: MaterialType.transparency,
      child: direction == null ? child : Directionality(textDirection: direction, child: child),
    ),
  );
}

// The pickers' routes build under the app's Navigator, above the card, so their content needs the fallback too.
Widget _withMaterialLocalizations(BuildContext context, Widget child) {
  if (Localizations.of<MaterialLocalizations>(context, MaterialLocalizations) != null) return child;
  return Localizations.override(
      context: context, delegates: const [DefaultMaterialLocalizations.delegate], child: child);
}

class _Card extends StatelessWidget {
  const _Card({required this.element, required this.children});

  final KidElementName element;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final appearance = KidCoreProvider.of(context).appearance;
    return _withMaterial(
      context,
      SizedBox(
        width: double.infinity,
        child: KidElement(
          appearance: appearance,
          keys: [KidElementName.card, element],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 12), child],
            ],
          ),
        ),
      ),
    );
  }
}

class _Text extends StatelessWidget {
  const _Text(this.element, this.text);

  final KidElementName element;
  final String text;

  @override
  Widget build(BuildContext context) =>
      KidElement(appearance: KidCoreProvider.of(context).appearance, keys: [element], child: Text(text));
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final appearance = KidCoreProvider.of(context).appearance;
    final style = resolveElementStyle(appearance, const [KidElementName.button]);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(style.cornerRadius ?? 0),
          child: KidElement(
            appearance: appearance,
            keys: const [KidElementName.button],
            child: Center(child: Text(label)),
          ),
        ),
      ),
    );
  }
}

/// A tappable field that shows [value], or [placeholder] when there is none.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, required this.placeholder, required this.onTap});

  final String label;
  final String? value;
  final String placeholder;

  /// Gets the field's context, which is under the card's Material localizations.
  final ValueChanged<BuildContext> onTap;

  @override
  Widget build(BuildContext context) {
    final appearance = KidCoreProvider.of(context).appearance;
    final text = value;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: () => onTap(context),
        child: KidElement(
          appearance: appearance,
          keys: const [KidElementName.input],
          child: SizedBox(
            width: double.infinity,
            child: text == null ? _Text(KidElementName.muted, placeholder) : Text(text),
          ),
        ),
      ),
    );
  }
}

class _Input extends StatelessWidget {
  const _Input({required this.controller, required this.placeholder, this.email = false, this.onChanged});

  final TextEditingController controller;
  final String placeholder;
  final bool email;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final appearance = KidCoreProvider.of(context).appearance;
    final v = appearance.variables;
    return KidElement(
      appearance: appearance,
      keys: const [KidElementName.input],
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: email ? TextInputType.emailAddress : TextInputType.text,
        autocorrect: false,
        enableSuggestions: !email,
        autofillHints: email ? const [AutofillHints.email] : null,
        style: TextStyle(color: v.colorText, fontFamily: v.fontFamily),
        cursorColor: v.colorPrimary,
        decoration: InputDecoration.collapsed(
          hintText: placeholder,
          hintStyle: TextStyle(color: v.colorTextMuted, fontFamily: v.fontFamily),
        ),
      ),
    );
  }
}

/// The jurisdiction picker. [onSelect] gets the chosen code. Shows only during the jurisdiction step.
class KidSelectJurisdiction extends StatefulWidget {
  const KidSelectJurisdiction({super.key, this.onSelect});

  final ValueChanged<String>? onSelect;

  @override
  State<KidSelectJurisdiction> createState() => _KidSelectJurisdictionState();
}

class _KidSelectJurisdictionState extends State<KidSelectJurisdiction> {
  String? _code;

  Future<void> _pick(BuildContext fieldContext) async {
    final core = KidCoreProvider.of(context);
    final picked = await showDialog<String>(
      context: fieldContext,
      builder: (routeContext) =>
          _withMaterialLocalizations(routeContext, _JurisdictionDialog(core: core, selected: _code)),
    );
    if (picked != null && mounted) setState(() => _code = picked);
  }

  @override
  Widget build(BuildContext context) {
    final gate = KidSessionProvider.of(context).gate;
    if (gate.state.step != AgeGateStep.jurisdiction) return const SizedBox.shrink();
    final core = KidCoreProvider.of(context);
    final t = core.strings.jurisdiction;
    final code = _code;
    final name = code == null ? null : core.jurisdictions.where((j) => j.code == code).firstOrNull?.name;
    return _Card(element: KidElementName.selectJurisdiction, children: [
      _Text(KidElementName.label, t.label),
      _Field(label: t.label, value: name, placeholder: t.placeholder, onTap: _pick),
      _Button(
        label: t.submit,
        onPressed: code == null
            ? null
            : () {
                gate.setJurisdiction(code);
                widget.onSelect?.call(code);
              },
      ),
    ]);
  }
}

class _JurisdictionDialog extends StatefulWidget {
  const _JurisdictionDialog({required this.core, required this.selected});

  final KidCoreContext core;
  final String? selected;

  @override
  State<_JurisdictionDialog> createState() => _JurisdictionDialogState();
}

class _JurisdictionDialogState extends State<_JurisdictionDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = widget.core;
    final appearance = core.appearance;
    final t = core.strings.jurisdiction;
    final options = matchingJurisdictions(core.jurisdictions, _query.text);
    final direction = core.direction;
    final dialog = Dialog(
      backgroundColor: Colors.transparent,
      child: KidElement(
        appearance: appearance,
        keys: const [KidElementName.card],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KidElement(appearance: appearance, keys: const [KidElementName.title], child: Text(t.label)),
            const SizedBox(height: 12),
            KidElement(
              appearance: appearance,
              keys: const [KidElementName.input],
              child: TextField(
                controller: _query,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration.collapsed(hintText: t.label),
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final option = options[i];
                  final selected = option.code == widget.selected;
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(option.code),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Semantics(
                        selected: selected,
                        child: Text(selected ? '${option.name} ✓' : option.name),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    return direction == null ? dialog : Directionality(textDirection: direction, child: dialog);
  }
}

/// The age step: [methods] is your preferred order of inputs, limited to what the jurisdiction approves (default: the
/// age slider, then date of birth). [onSubmit] gets the age. Shows only during the age step.
class KidCollectAge extends StatefulWidget {
  const KidCollectAge({super.key, this.methods, this.onSubmit});

  final List<KidAgeMethod>? methods;
  final ValueChanged<AgeSignal>? onSubmit;

  @override
  State<KidCollectAge> createState() => _KidCollectAgeState();
}

class _KidCollectAgeState extends State<KidCollectAge> {
  String? _dateOfBirth;
  int? _age;

  Future<void> _pickDate(BuildContext fieldContext) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: fieldContext,
      builder: (routeContext, child) => _withMaterialLocalizations(routeContext, child!),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
      initialDate: now,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null && mounted) setState(() => _dateOfBirth = _isoDay(picked));
  }

  @override
  Widget build(BuildContext context) {
    final gate = KidSessionProvider.of(context).gate;
    final state = gate.state;
    final approved = state.requirements?.approvedAgeCollectionMethods;
    if (state.step != AgeGateStep.age || approved == null) return const SizedBox.shrink();
    final allowed = [
      for (final m in KidAgeMethod.values)
        if (approved.contains(m.value)) m,
    ];
    final method = (widget.methods ?? _defaultAgeMethods).where(allowed.contains).firstOrNull ?? allowed.firstOrNull;
    if (method == null) return const SizedBox.shrink();
    final core = KidCoreProvider.of(context);
    final t = core.strings.age;
    final v = core.appearance.variables;

    void submit() {
      final dateOfBirth = _dateOfBirth;
      final age = _age;
      final AgeSignal signal;
      if (method == KidAgeMethod.dateOfBirth && dateOfBirth != null) {
        signal = AgeSignal.dateOfBirth(dateOfBirth);
      } else if (method == KidAgeMethod.ageSlider && age != null) {
        signal = AgeSignal.age(age);
      } else {
        return;
      }
      gate.setAge(signal);
      widget.onSubmit?.call(signal);
    }

    final ready = method == KidAgeMethod.dateOfBirth ? _dateOfBirth != null : _age != null;
    if (method == KidAgeMethod.dateOfBirth) {
      return _Card(element: KidElementName.collectAge, children: [
        _Text(KidElementName.label, t.dateOfBirthLabel),
        _Field(label: t.dateOfBirthLabel, value: _dateOfBirth, placeholder: 'yyyy-mm-dd', onTap: _pickDate),
        _Button(label: t.submit, onPressed: ready ? submit : null),
      ]);
    }
    final age = _age;
    final label = format(t.ageLabel, {'age': age == null ? '-' : (age == _maxSliderAge ? '$age+' : '$age')});
    return _Card(element: KidElementName.collectAge, children: [
      _Text(KidElementName.label, label),
      Slider(
        value: (age ?? 1).toDouble(),
        min: 1,
        max: _maxSliderAge.toDouble(),
        divisions: _maxSliderAge - 1,
        activeColor: v.colorPrimary,
        inactiveColor: v.colorBorder,
        semanticFormatterCallback: (_) => label,
        onChanged: (value) => setState(() => _age = value.round()),
      ),
      _Button(label: t.submit, onPressed: ready ? submit : null),
    ]);
  }
}

class _ChallengeEmailForm extends StatefulWidget {
  const _ChallengeEmailForm({
    required this.strings,
    required this.element,
    required this.setEmail,
    required this.send,
    this.onSent,
  });

  final KidEmailStrings Function(KidStrings strings) strings;
  final KidElementName element;
  final void Function(String email) setEmail;
  final Future<KidResult> Function() send;
  final ValueChanged<String>? onSent;

  @override
  State<_ChallengeEmailForm> createState() => _ChallengeEmailFormState();
}

class _ChallengeEmailFormState extends State<_ChallengeEmailForm> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit(KidEmailStrings t) async {
    final email = _email.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.setEmail(email);
    final res = await widget.send();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!res.ok) _error = res.error?.code == KidErrorCode.invalidRequest ? t.invalidEmail : t.error;
    });
    if (res.ok) widget.onSent?.call(email);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.strings(KidCoreProvider.of(context).strings);
    final error = _error;
    return _Card(element: widget.element, children: [
      _Text(KidElementName.label, t.title),
      _Text(KidElementName.muted, t.description),
      _Input(controller: _email, placeholder: t.emailPlaceholder, email: true, onChanged: (_) => setState(() {})),
      _Button(
        label: _busy ? t.submitting : t.submit,
        onPressed: !_busy && _isValidEmail(_email.text.trim()) ? () => _submit(t) : null,
      ),
      if (error != null) Semantics(liveRegion: true, child: _Text(KidElementName.danger, error)),
    ]);
  }
}

class _GateEmailForm extends StatelessWidget {
  const _GateEmailForm({required this.step, required this.strings, required this.element, this.onSent});

  final AgeGateStep step;
  final KidEmailStrings Function(KidStrings strings) strings;
  final KidElementName element;
  final ValueChanged<String>? onSent;

  @override
  Widget build(BuildContext context) {
    final gate = KidSessionProvider.of(context).gate;
    if (gate.state.step != step || gate.state.emailProvided) return const SizedBox.shrink();
    return _ChallengeEmailForm(
      strings: strings,
      element: element,
      setEmail: gate.setEmail,
      send: gate.submit,
      onSent: onSent,
    );
  }
}

/// The grownup's email, with a built-in send. [onSent] gets the email once it has gone out.
class KidAskAnAdult extends StatelessWidget {
  const KidAskAnAdult({super.key, this.onSent});

  final ValueChanged<String>? onSent;

  @override
  Widget build(BuildContext context) => _GateEmailForm(
        step: AgeGateStep.parentalConsent,
        strings: (s) => s.askAnAdult,
        element: KidElementName.askAnAdult,
        onSent: onSent,
      );
}

/// For an adults-only product: emails the player a link to verify their age on k-ID. [onSent] gets the email once it
/// has gone out.
class KidVerifyAge extends StatelessWidget {
  const KidVerifyAge({super.key, this.onSent});

  final ValueChanged<String>? onSent;

  @override
  Widget build(BuildContext context) => _GateEmailForm(
        step: AgeGateStep.ageAssurance,
        strings: (s) => s.verifyAge,
        element: KidElementName.verifyAge,
        onSent: onSent,
      );
}

/// The drop-in age gate: draws the capture while it runs, then the widget for its outcome, and nothing for one you
/// leave out. Provide at least [pass]. There is no reset: recreate the [KidSessionProvider] to start over.
class KidAgeGate extends StatelessWidget {
  const KidAgeGate({super.key, this.pass, this.pending, this.prohibited, this.fail, this.error});

  final Widget? pass;

  /// Consent requested, waiting on the grownup.
  final Widget? pending;

  /// Under the minimum age for the jurisdiction.
  final Widget? prohibited;

  /// Consent denied or the challenge expired.
  final Widget? fail;

  /// k-ID could not be reached or rate limited; read the error from `KidSessionProvider.of(context).ageGate.error`.
  final Widget? error;

  @override
  Widget build(BuildContext context) {
    final status = KidSessionProvider.of(context).ageGate.status;
    final none = const SizedBox.shrink();
    return switch (status) {
      KidStatus.running => const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [KidSelectJurisdiction(), KidCollectAge(), KidAskAnAdult(), KidVerifyAge()],
        ),
      KidStatus.pending => pending ?? none,
      KidStatus.pass => pass ?? none,
      KidStatus.prohibited => prohibited ?? none,
      KidStatus.fail => fail ?? none,
      KidStatus.error => error ?? none,
    };
  }
}

/// Verifies the player is an adult (the civil age of their jurisdiction) on the established session: the email form
/// while it needs the player's email, then the widget for the outcome. Shows nothing until the age gate passes. Showing
/// it again after a fail or error tries again.
class KidSessionVerifyAge extends StatefulWidget {
  const KidSessionVerifyAge({super.key, this.onSent, this.pass, this.pending, this.fail, this.error});

  final ValueChanged<String>? onSent;

  /// The session is a verified adult.
  final Widget? pass;

  /// The link is sent, waiting for the player to verify.
  final Widget? pending;

  /// The player could not prove they are an adult.
  final Widget? fail;

  /// k-ID could not be reached or rate limited.
  final Widget? error;

  @override
  State<KidSessionVerifyAge> createState() => _KidSessionVerifyAgeState();
}

class _KidSessionVerifyAgeState extends State<KidSessionVerifyAge> {
  VerifyAgeController? _started;

  @override
  Widget build(BuildContext context) {
    final controller = KidSessionProvider.of(context).gate.sessionVerifyAge;
    if (controller == null) return const SizedBox.shrink();
    if (!identical(controller, _started)) {
      _started = controller;
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.start());
    }
    final state = controller.state;
    final none = const SizedBox.shrink();
    return switch (state.status) {
      KidStatus.running => state.step == VerifyAgeStep.email
          ? _ChallengeEmailForm(
              strings: (s) => s.verifyAge,
              element: KidElementName.verifyAge,
              setEmail: controller.setEmail,
              send: controller.submit,
              onSent: widget.onSent,
            )
          : none,
      KidStatus.pending => widget.pending ?? none,
      KidStatus.pass => widget.pass ?? none,
      KidStatus.fail => widget.fail ?? none,
      KidStatus.error => widget.error ?? none,
      KidStatus.prohibited => none,
    };
  }
}

/// Shows [child] when [name] is enabled for the player, else [fallback]. It gates what a player sees; enforce the real
/// capability server-side.
class KidPermission extends StatelessWidget {
  const KidPermission({super.key, required this.name, this.fallback, required this.child});

  final PermissionName name;
  final Widget? fallback;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final can = KidSessionProvider.of(context).permission.can(name);
    return can ? child : (fallback ?? const SizedBox.shrink());
  }
}
