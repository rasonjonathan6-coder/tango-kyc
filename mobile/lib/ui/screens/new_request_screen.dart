/// Form to submit a new manual KYC verification request.
///
/// Reached from the home screen ("Nouvelle demande"). On success it pops with
/// `true` so the caller can refresh and confirm; it does not render the ticket
/// itself.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../state/kyc_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class NewRequestScreen extends StatefulWidget {
  const NewRequestScreen({super.key});

  @override
  State<NewRequestScreen> createState() => _NewRequestScreenState();
}

class _NewRequestScreenState extends State<NewRequestScreen> {
  final _profileLinkController = TextEditingController();
  final _registerController = TextEditingController();

  String? _profileLinkError;
  String? _registerError;

  @override
  void dispose() {
    _profileLinkController.dispose();
    _registerController.dispose();
    super.dispose();
  }

  /// Live hint so the user can see how their input will be interpreted.
  String? get _detectedHint {
    final value = Validators.normalize(_registerController.text);
    if (value.isEmpty) return null;
    return Validators.looksLikeEmail(value)
        ? 'Will be registered as an email address.'
        : 'Will be registered as a phone number.';
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final validation = Validators.validateRequestForm(
      profileLink: _profileLinkController.text,
      registerValue: _registerController.text,
    );
    setState(() {
      _profileLinkError = validation.profileLinkError;
      _registerError = validation.registerError;
    });
    if (!validation.isValid) return;

    final controller = context.read<KycController>();
    final ticket = await controller.submit(
      tangoProfileLink: Validators.normalize(_profileLinkController.text),
      registerValue: Validators.normalize(_registerController.text),
    );

    if (!mounted) return;

    if (ticket == null) {
      final code = controller.lastErrorCode ?? 'INTERNAL';
      setState(() {
        if (code == 'PROFILE_LINK_REQUIRED' ||
            code == 'PROFILE_LINK_INVALID' ||
            code == 'PROFILE_LINK_TOO_LONG') {
          _profileLinkError = ErrorMessages.from(code);
        }
        if (code == 'REGISTER_REQUIRED' ||
            code == 'REGISTER_EMAIL_INVALID' ||
            code == 'REGISTER_PHONE_INVALID') {
          _registerError = ErrorMessages.from(code);
        }
      });

      final isFieldError = code == 'PROFILE_LINK_REQUIRED' ||
          code == 'PROFILE_LINK_INVALID' ||
          code == 'PROFILE_LINK_TOO_LONG' ||
          code == 'REGISTER_REQUIRED' ||
          code == 'REGISTER_EMAIL_INVALID' ||
          code == 'REGISTER_PHONE_INVALID';
      if (!isFieldError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessages.from(code)),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
      return;
    }

    controller.clearLastCreated();
    // Hand the created request back so the caller can route to the MVola
    // payment when the backend reports that a payment is still required. The
    // request is not presented as "sent" until that payment is validated.
    Navigator.of(context).pop(ticket);
  }

  @override
  Widget build(BuildContext context) {
    final submitting = context.watch<KycController>().submitting;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Nouvelle demande')),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.assignment_turned_in_rounded,
                          size: 22, color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Text(
                        'Manual KYC Verification',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  LabeledField(
                    label: 'Tango Profile Link',
                    controller: _profileLinkController,
                    hint: 'https://...',
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    errorText: _profileLinkError,
                    enabled: !submitting,
                    validator: Validators.validateProfileLink,
                  ),
                  const SizedBox(height: 20),
                  LabeledField(
                    label: 'Register Email or Phone Number',
                    controller: _registerController,
                    hint: 'Email or phone number',
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    errorText: _registerError,
                    helper: _detectedHint,
                    enabled: !submitting,
                    validator: Validators.validateRegisterValue,
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 26),
                  FilledButton(
                    onPressed: submitting ? null : _submit,
                    child: submitting
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2.4),
                              ),
                              SizedBox(width: 12),
                              Text('Sending...'),
                            ],
                          )
                        : const Text('Envoyer ma demande'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
