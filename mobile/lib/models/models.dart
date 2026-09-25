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
    this.messageCount,
    this.userEmail,
    this.userDisplayName,
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

  /// Present only in the admin listing.
  final int? messageCount;
  final String? userEmail;
  final String? userDisplayName;

  factory KycRequest.fromMap(Map<String, dynamic> map) => KycRequest(
        id: map['id'] as String,
        ticketCode: (map['ticket_code'] as String?) ?? '',
        tangoProfileLink: (map['tango_profile_link'] as String?) ?? '',
        registerType: RegisterType.parse(map['register_type'] as String?) ?? RegisterType.email,
        registerValue: (map['register_value'] as String?) ?? '',
        status: KycStatus.parse(map['status'] as String?),
        createdAt: DateTime.tryParse((map['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        updatedAt: DateTime.tryParse((map['updated_at'] as String?) ?? '')?.toLocal(),
        lastReplyAt: DateTime.tryParse((map['last_reply_at'] as String?) ?? '')?.toLocal(),
        messageCount: (map['message_count'] as num?)?.toInt(),
        userEmail: map['user_email'] as String?,
        userDisplayName: map['user_display_name'] as String?,
      );
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
