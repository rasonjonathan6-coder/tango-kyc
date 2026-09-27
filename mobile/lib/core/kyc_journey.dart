/// Presentation logic for the KYC journey: which step the user is on, and how the
/// status should be phrased on the dashboard.
///
/// Kept free of Flutter imports so it can be unit tested directly, and so the
/// user-facing wording has a single source of truth shared by the dashboard, the
/// detail screen and the history list.
library;

import '../models/models.dart';

/// The four stages of a manual KYC request, in order.
enum KycStep {
  submitted,
  payment,
  review,
  answer;

  /// Human label shown in the journey timeline.
  String get label => switch (this) {
        KycStep.submitted => 'Request submitted',
        KycStep.payment => 'MVola payment',
        KycStep.review => 'Manual review',
        KycStep.answer => 'Answer from support',
      };

  /// 1-based position, for progress display.
  int get position => index + 1;

  static const int total = 4;
}

/// A short, plain-language sentence describing what happens next.
///
/// Written so a user who knows nothing about the backend understands their
/// situation from the dashboard alone.
///
/// The payment step only exists when the administration has explicitly asked for
/// it ([paymentRequired]). A request that still owes a payment must be told to
/// pay and must never be presented as "received"; once the payment has been
/// validated ([isSubmitted]) it has reached the review stage. A request that owes
/// nothing reads as an acknowledgement.
String nextActionHint(
  KycStatus status, {
  bool paymentRequired = false,
  bool isSubmitted = false,
}) =>
    switch (status) {
      KycStatus.pending => paymentRequired
          ? (isSubmitted
              ? 'Your request has been received. Support will review it shortly.'
              : 'Your request is ready. Complete the MVola payment to finalise the submission.')
          : 'Your request has been received. Support will review it shortly.',
      KycStatus.inReview => 'Support is reviewing your documents. No action needed.',
      KycStatus.replied => 'Support replied. Open the ticket to read the message.',
      KycStatus.closed => 'This request is closed. You can submit a new one if needed.',
    };

/// The furthest step reached for a given status.
///
/// The mapping is deliberately conservative: a payment is only part of the
/// journey once the administration has actually requested one
/// ([paymentRequired]), and the journey only leaves the payment step once that
/// payment has been validated ([isSubmitted]). A request still awaiting payment
/// must not be shown as submitted, and an approved payment that has not yet
/// moved the ticket must not keep asking for a payment.
KycStep currentStep(
  KycStatus status, {
  bool paymentRequired = false,
  bool isSubmitted = false,
}) =>
    switch (status) {
      KycStatus.pending => paymentRequired
          ? (isSubmitted ? KycStep.review : KycStep.submitted)
          : KycStep.submitted,
      KycStatus.inReview => KycStep.review,
      KycStatus.replied => KycStep.answer,
      KycStatus.closed => KycStep.answer,
    };

/// Whether a given step is complete for a status.
bool isStepDone(
  KycStatus status,
  KycStep step, {
  bool paymentRequired = false,
  bool isSubmitted = false,
}) =>
    step.index <=
    currentStep(status, paymentRequired: paymentRequired, isSubmitted: isSubmitted).index;

/// Builds the ordered timeline for a status, ready to render.
List<({String label, bool done})> journeyFor(
  KycStatus status, {
  bool paymentRequired = false,
  bool isSubmitted = false,
}) => [
      for (final step in KycStep.values)
        (
          label: step.label,
          done: isStepDone(
            status,
            step,
            paymentRequired: paymentRequired,
            isSubmitted: isSubmitted,
          ),
        ),
    ];
