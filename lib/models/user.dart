// models/user.dart

enum UserRole { owner, member }

class User {
  final String id;
  final String name;
  final String email;
  final String? avatarUrl;

  // Role-Based features
  final UserRole role;
  final String? houseId;
  final String? houseName;
  final bool isApproved;
  final String? joinCode;

  /// Room IDs the owner has assigned to this member.
  /// Owners always have full access — this list is only meaningful for members.
  final List<String> assignedRoomIds;

  User({
    required this.id,
    required this.name,
    required this.email,
    this.avatarUrl,
    this.role = UserRole.owner,
    this.houseId,
    this.houseName,
    this.isApproved = true,
    this.joinCode,
    this.assignedRoomIds = const [],
  });

  /// Riverpod ke userProvider mein data update karne ke liye
  User copyWith({
    String? id,
    String? name,
    String? email,
    String? avatarUrl,
    UserRole? role,
    String? houseId,
    String? houseName,
    bool? isApproved,
    String? joinCode,
    List<String>? assignedRoomIds,
  }) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      role: role ?? this.role,
      houseId: houseId ?? this.houseId,
      houseName: houseName ?? this.houseName,
      isApproved: isApproved ?? this.isApproved,
      joinCode: joinCode ?? this.joinCode,
      assignedRoomIds: assignedRoomIds ?? this.assignedRoomIds,
    );
  }

  /// Firestore mein data save karne ke liye (Object to JSON)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'avatarUrl': avatarUrl,
      'role': role.name,
      'houseId': houseId,
      'houseName': houseName,
      'isApproved': isApproved,
      'joinCode': joinCode,
      'assignedRoomIds': assignedRoomIds,
    };
  }

  /// Firestore se data read karne ke liye (JSON to Object)
  factory User.fromMap(Map<String, dynamic> map) {
    final rawIds = map['assignedRoomIds'];
    final ids = rawIds is List
        ? rawIds.whereType<String>().toList()
        : <String>[];
    return User(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      avatarUrl: map['avatarUrl'],
      role: map['role'] == 'member' ? UserRole.member : UserRole.owner,
      houseId: map['houseId'],
      houseName: map['houseName'],
      isApproved: map['isApproved'] ?? true,
      joinCode: map['joinCode'],
      assignedRoomIds: ids,
    );
  }
}