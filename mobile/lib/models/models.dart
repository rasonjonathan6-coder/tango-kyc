/// Domain models mirroring the Supabase schema.
///
/// Only fields a user is allowed to see are mapped. Nothing here can be written
/// back to the server except through the documented Edge Functions.
library;

/// Whether a request was registered with an email address or a phone number.
enum RegisterType {
  email,
  phone;

  static RegisterType? parse(String? value) => switch (value) {
        'email' => RegisterType.email,
        'phone' => RegisterType.phone,
        _ => null,
      };

  String get label => switch (this) {
        RegisterType.email => 'Register email',
        RegisterType.phone => 'Register number',
      };
}

/// Ticket lifecycle. `replied` is what the user sees as "Reply received".
enum KycStatus {
  pending,
  inReview,
  replied,
  closed;

  static KycStatus parse(String? value) => switch (value) {
        'pending' => KycStatus.pending,
        'in_review' => KycStatus.inReview,
        'replied' => KycStatus.replied,
        'closed' => KycStatus.closed,
        _ => KycStatus.pending,
      };

  String get wireValue => switch (this) {
        KycStatus.pending => 'pending',
        KycStatus.inReview => 'in_review',
        KycStatus.replied => 'replied',
        KycStatus.closed => 'closed',
      };

  String get label => switch (this) {
        KycStatus.pending => 'Pending',
        KycStatus.inReview => 'In review',
        KycStatus.replied => 'Reply received',
        KycStatus.closed => 'Closed',
      };
}

enum SenderType {
  user,
  admin,
  system;

  static SenderType parse(String? value) => switch (value) {
        'admin' => SenderType.admin,
        'system' => SenderType.system,
        _ => SenderType.user,
      };

  String get label => switch (this) {
        SenderType.user => 'You',
        SenderType.admin => 'Support',
        SenderType.system => 'System',
      };
}

class Profile {
  const Profile({
    required this.id,
    this.email,
    this.displayName,
    this.avatarUrl,
    required this.role,
  });

  final String id;
  final String? email;
  final String? displayName;
  final String? avatarUrl;
  final String role;

  bool get isAdmin => role == 'admin';

  /// First name when the user supplied a full name, otherwise the whole value.
  String get greetingName {
    final name = displayName?.trim();
    if (name == null || name.isEmpty) {
      final mail = email ?? '';
      return mail.contains('@') ? mail.split('@').first : (mail.isEmpty ? 'there' : mail);
    }
    return name.split(RegExp(r'\s+')).first;
  }

  factory Profile.fromMap(Map<String, dynamic> map) => Profile(
        id: map['id'] as String,
        email: map['email'] as String?,
        displayName: map['display_name'] as String?,
        avatarUrl: map['avatar_url'] as String?,
        role: (map['role'] as String?) ?? 'user',
      );
}

class KycRequest {
  const KycRequest({
    required this.id,
    required this.ticketCode,
    required this.tangoProfileLink,
    required this.registerType,
    required this.registerValue,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.lastReplyAt,
    this.paymentRequired = false,
    this.paymentRequestedAt,
    this.messageCount,
    this.userEmail,
    this.userDisplayName,
    this.isSubmitted = true,
    this.paymentStatus,
  });

  final String id;
  final String ticketCode;
  final String tangoProfileLink;
  final RegisterType registerType;
  final String registerValue;
  final KycStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? lastReplyAt;

  /// Set by the administration when a payment is actually needed for this
  /// request. The payment UI is only offered when this is true.
  final bool paymentRequired;
  final DateTime? paymentRequestedAt;

  /// Present only in the admin listing.
  final int? messageCount;
  final String? userEmail;
  final String? userDisplayName;

  /// Server-derived flag: the request is only officially submitted once its
  /// MVola payment has been validated (or immediately when MVola is disabled).
  /// Never inferred from client state.
  final bool isSubmitted;

  /// Server-derived payment status: e.g. `not_required`, `awaiting_submission`,
  /// `pending`, `approved`, `rejected`, `none`.
  final String? paymentStatus;

  factory KycRequest.fromMap(Map<String, dynamic> map) {
    // The submission state is derived on the server when it is returned by the
    // create function, and from the embedded payment rows on the read path. It
    // is never taken from client-side mutable state.
    final embeddedPayments = map['mvola_payments'];
    String? paymentStatus = map['payment_status'] as String?;
    bool? isSubmitted = map['is_submitted'] as bool?;
    if (embeddedPayments is List) {
      final statuses = embeddedPayments
          .whereType<Map<String, dynamic>>()
          .map((row) => row['status'] as String?)
          .whereType<String>()
          .toList();
      paymentStatus = statuses.contains('approved')
          ? 'approved'
          : (statuses.isEmpty ? 'awaiting_submission' : statuses.first);
      isSubmitted = !((map['payment_required'] as bool?) ?? false) ||
          statuses.contains('approved');
    }

    return KycRequest(
      id: map['id'] as String,
      ticketCode: (map['ticket_code'] as String?) ?? '',
      tangoProfileLink: (map['tango_profile_link'] as String?) ?? '',
      registerType: RegisterType.parse(map['register_type'] as String?) ?? RegisterType.email,
      registerValue: (map['register_value'] as String?) ?? '',
      status: KycStatus.parse(map['status'] as String?),
      createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
      updatedAt: DateTime.tryParse((map['updated_at'] as String?) ?? '')?.toLocal(),
      lastReplyAt: DateTime.tryParse((map['last_reply_at'] as String?) ?? '')?.toLocal(),
      paymentRequired: (map['payment_required'] as bool?) ?? false,
      paymentRequestedAt:
          DateTime.tryParse((map['payment_requested_at'] as String?) ?? '')?.toLocal(),
      messageCount: (map['message_count'] as num?)?.toInt(),
      userEmail: map['user_email'] as String?,
      userDisplayName: map['user_display_name'] as String?,
      // Absent fields default to "submitted" so a payload that predates this
      // field (e.g. an older function) never falsely blocks the user.
      isSubmitted: isSubmitted ?? true,
      paymentStatus: paymentStatus,
    );
  }
}

class TicketMessage {
  const TicketMessage({
    required this.id,
    required this.ticketId,
    required this.senderType,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String ticketId;
  final SenderType senderType;
  final String body;
  final DateTime createdAt;

  factory TicketMessage.fromMap(Map<String, dynamic> map) => TicketMessage(
        id: map['id'] as String,
        ticketId: (map['ticket_id'] as String?) ?? '',
        senderType: SenderType.parse(map['sender_type'] as String?),
        body: (map['body'] as String?) ?? '',
        createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
      );
}

/// Manual MVola payment lifecycle.
///
/// `pending` covers two situations the UI distinguishes by `submittedAt`: not
/// yet confirmed by the user, or awaiting admin verification. Only an admin can
/// reach `approved` or `rejected`.
enum MvolaStatus {
  pending,
  approved,
  rejected,
  cancelled;

  static MvolaStatus parse(String? value) => switch (value) {
        'approved' => MvolaStatus.approved,
        'rejected' => MvolaStatus.rejected,
        'cancelled' => MvolaStatus.cancelled,
        _ => MvolaStatus.pending,
      };

  String get label => switch (this) {
        MvolaStatus.pending => 'Pending',
        MvolaStatus.approved => 'Approved',
        MvolaStatus.rejected => 'Refused',
        MvolaStatus.cancelled => 'Cancelled',
      };
}

/// The payer-facing payment instructions. Every value comes from server
/// configuration; none of it is hard-coded in the app.
class MvolaConfig {
  const MvolaConfig({
    required this.recipientNumber,
    required this.amount,
    required this.currency,
    required this.ussdCode,
    required this.instructions,
  });

  final String recipientNumber;
  final double amount;
  final String currency;
  final String ussdCode;
  final String instructions;

  /// The amount as it should be shown: no trailing `.0` for whole amounts.
  String get amountLabel {
    final whole = amount == amount.roundToDouble();
    return '${whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2)} $currency';
  }

  factory MvolaConfig.fromMap(Map<String, dynamic> map) => MvolaConfig(
        recipientNumber: (map['recipient_number'] as String?) ?? '',
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
        currency: (map['currency'] as String?) ?? 'MGA',
        ussdCode: (map['ussd_code'] as String?) ?? '',
        instructions: (map['instructions'] as String?) ?? '',
      );
}

class MvolaPayment {
  const MvolaPayment({
    required this.id,
    required this.ticketId,
    required this.amount,
    required this.currency,
    required this.recipientNumber,
    required this.ussdCode,
    required this.status,
    required this.createdAt,
    this.payerNumber,
    this.transactionReference,
    this.rejectionReason,
    this.submittedAt,
    this.reviewedAt,
    this.ticketCode,
    this.userEmail,
  });

  final String id;
  final String ticketId;
  final double amount;
  final String currency;
  final String recipientNumber;
  final String ussdCode;
  final MvolaStatus status;
  final DateTime createdAt;
  final String? payerNumber;
  final String? transactionReference;
  final String? rejectionReason;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;

  /// Present only in the admin listing.
  final String? ticketCode;
  final String? userEmail;

  /// True once the user confirmed they paid; still awaiting an admin decision.
  bool get isAwaitingReview =>
      status == MvolaStatus.pending && submittedAt != null;

  String get amountLabel {
    final whole = amount == amount.roundToDouble();
    return '${whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2)} $currency';
  }

  factory MvolaPayment.fromMap(Map<String, dynamic> map) => MvolaPayment(
        id: map['id'] as String,
        ticketId: (map['ticket_id'] as String?) ?? '',
        amount: (map['amount'] as num?)?.toDouble() ?? 0,
        currency: (map['currency'] as String?) ?? 'MGA',
        recipientNumber: (map['recipient_number'] as String?) ?? '',
        ussdCode: (map['ussd_code'] as String?) ?? '',
        status: MvolaStatus.parse(map['status'] as String?),
        createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        payerNumber: map['payer_number'] as String?,
        transactionReference: map['transaction_reference'] as String?,
        rejectionReason: map['rejection_reason'] as String?,
        submittedAt: DateTime.tryParse((map['submitted_at'] as String?) ?? '')?.toLocal(),
        reviewedAt: DateTime.tryParse((map['reviewed_at'] as String?) ?? '')?.toLocal(),
        ticketCode: map['ticket_code'] as String?,
        userEmail: map['user_email'] as String?,
      );
}

class UnmatchedReply {
  const UnmatchedReply({
    required this.id,
    required this.fromEmail,
    required this.subject,
    required this.bodyExcerpt,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String? fromEmail;
  final String? subject;
  final String? bodyExcerpt;
  final String reason;
  final DateTime createdAt;

  factory UnmatchedReply.fromMap(Map<String, dynamic> map) => UnmatchedReply(
        id: map['id'] as String,
        fromEmail: map['from_email'] as String?,
        subject: map['subject'] as String?,
        bodyExcerpt: map['body_excerpt'] as String?,
        reason: (map['reason'] as String?) ?? '',
        createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
      );
}

class AdminStats {
  const AdminStats({
    required this.total,
    required this.pending,
    required this.inReview,
    required this.replied,
    required this.closed,
    required this.unmatched,
  });

  final int total;
  final int pending;
  final int inReview;
  final int replied;
  final int closed;
  final int unmatched;

  factory AdminStats.fromMap(Map<String, dynamic> map) => AdminStats(
        total: (map['total'] as num?)?.toInt() ?? 0,
        pending: (map['pending'] as num?)?.toInt() ?? 0,
        inReview: (map['in_review'] as num?)?.toInt() ?? 0,
        replied: (map['replied'] as num?)?.toInt() ?? 0,
        closed: (map['closed'] as num?)?.toInt() ?? 0,
        unmatched: (map['unmatched'] as num?)?.toInt() ?? 0,
      );


  static const empty = AdminStats(
    total: 0,
    pending: 0,
    inReview: 0,
    replied: 0,
    closed: 0,
    unmatched: 0,
  );
}

/// A single persisted notification belonging to exactly one user.
class NotificationItem {
  const NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.ticketId,
    this.readAt,
  });

  final String id;
  final String type;
  final String title;
  final String body;
  final DateTime createdAt;
  final String? ticketId;
  final DateTime? readAt;

  bool get unread => readAt == null;

  factory NotificationItem.fromMap(Map<String, dynamic> map) => NotificationItem(
        id: map['id'] as String,
        type: (map['type'] as String?) ?? '',
        title: (map['title'] as String?) ?? '',
        body: (map['body'] as String?) ?? '',
        createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        ticketId: map['ticket_id'] as String?,
        readAt: DateTime.tryParse((map['read_at'] as String?) ?? '')?.toLocal(),
      );
}

/// One row of a ticket's append-only status history.
class StatusHistoryEntry {
  const StatusHistoryEntry({
    required this.id,
    required this.toStatus,
    required this.actorRole,
    required this.createdAt,
    this.fromStatus,
  });

  final String id;
  final KycStatus? fromStatus;
  final KycStatus toStatus;
  final String actorRole;
  final DateTime createdAt;

  factory StatusHistoryEntry.fromMap(Map<String, dynamic> map) => StatusHistoryEntry(
        id: map['id'] as String,
        fromStatus: map['from_status'] == null ? null : KycStatus.parse(map['from_status'] as String?),
        toStatus: KycStatus.parse(map['to_status'] as String?),
        actorRole: (map['actor_role'] as String?) ?? 'system',
        createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
      );
}
