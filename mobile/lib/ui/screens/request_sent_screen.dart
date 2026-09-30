/// Outcome screen shown after a request has been created and the MVola payment
/// screen has been presented.
///
/// It replaces the plain snackbar the app used to show: the reference artwork
/// gives this moment a dedicated page (screen 15), which is also a better place
/// to explain what happens next.
///
/// The screen is purely presentational. It does not create anything: the caller
/// decides the wording from the server-reported state ([awaitingPayment]) and
/// passes in the follow-up actions through `onPrimary` / `onSecondary`. It must
/// never claim the request was sent while a payment is still owed: MVola is a
/// manual flow, so "sent" is only shown once the payment is really validated.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/tango_scaffold.dart';

class RequestSentScreen extends StatelessWidget {
  const RequestSentScreen({
    super.key,
    required this.ticketCode,
    required this.onPrimary,
    required this.onSecondary,
    this.awaitingPayment = false,
  });

  /// The real ticket code returned by the server.
  final String ticketCode;

  /// The emphasised follow-up action: open the request, or resume the payment
  /// while it is still owed.
  final VoidCallback onPrimary;

  /// The quiet action: go back to where the user came from.
  final VoidCallback onSecondary;

  /// True while the request still owes an MVola payment and is therefore not yet
  /// officially submitted. The wording changes, nothing else does.
  final bool awaitingPayment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TangoKycScaffold(
      safeArea: false,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 24, 26, 26),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Reveal(
                      child: Center(
                        child: Container(
                          height: 116,
                          width: 116,
                          decoration: BoxDecoration(
                            gradient: AppTheme.actionGradient,
                            shape: BoxShape.circle,
                            boxShadow: AppTheme.glow(AppColors.rose, opacity: 0.45, blur: 34),
                          ),
                          child: const Icon(Icons.check_rounded, size: 62, color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Reveal(
                      delay: const Duration(milliseconds: 70),
                      child: Text(
                        awaitingPayment ? 'Paiement en attente' : 'Demande envoyée !',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Reveal(
                      delay: const Duration(milliseconds: 110),
                      child: Text(
                        awaitingPayment
                            ? 'Votre demande est enregistrée. Le paiement MVola '
                                  'n’est pas encore confirmé : la demande sera '
                                  'transmise dès que le support aura validé le '
                                  'transfert.'
                            : 'Paiement confirmé. Votre demande a bien été envoyée '
                                  'et transmise au support. Vous recevrez une réponse '
                                  'par email et une notification dans l’application.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.55,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Reveal(
                      delay: const Duration(milliseconds: 150),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.confirmation_number_rounded,
                                size: 15,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                ticketCode,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 34),
                    Reveal(
                      delay: const Duration(milliseconds: 190),
                      child: GradientButton(
                        onPressed: onPrimary,
                        height: 56,
                        radius: 30,
                        icon: awaitingPayment
                            ? Icons.account_balance_wallet_rounded
                            : Icons.chat_bubble_outline_rounded,
                        child: Text(
                          awaitingPayment ? 'Reprendre le paiement MVola' : 'Voir la demande',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Reveal(
                      delay: const Duration(milliseconds: 230),
                      child: TextButton(
                        onPressed: onSecondary,
                        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        child: Text(awaitingPayment ? 'Voir la demande' : 'Retour à l’accueil'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
