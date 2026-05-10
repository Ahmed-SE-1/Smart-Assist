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
  final String? houseName; // NEW: House Name / Number add kar diya
  final bool isApproved;
  final String? joinCode;

  User({
    required this.id,
    required this.name,
    required this.email,
    this.avatarUrl,
    this.role = UserRole.owner,
    this.houseId,
    this.houseName, // NEW
    this.isApproved = true,
    this.joinCode,
  });

  /// Riverpod ke userProvider mein data update karne ke liye
  User copyWith({
    String? id,
    String? name,
    String? email,
    String? avatarUrl,
    UserRole? role,
    String? houseId,
    String? houseName, // NEW
    bool? isApproved,
    String? joinCode,
  }) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      role: role ?? this.role,
      houseId: houseId ?? this.houseId,
      houseName: houseName ?? this.houseName, // NEW
      isApproved: isApproved ?? this.isApproved,
      joinCode: joinCode ?? this.joinCode,
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
      'houseName': houseName, // NEW: Database mein ab yeh save hoga
      'isApproved': isApproved,
      'joinCode': joinCode,
    };
  }

  /// Firestore se data read karne ke liye (JSON to Object)
  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      avatarUrl: map['avatarUrl'],
      role: map['role'] == 'member' ? UserRole.member : UserRole.owner,
      houseId: map['houseId'],
      houseName: map['houseName'], // NEW: Database se read hoga
      isApproved: map['isApproved'] ?? true,
      joinCode: map['joinCode'],
    );
  }
}