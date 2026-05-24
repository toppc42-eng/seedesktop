/// Nested menu layout for the dynamic user menu builder (Mission 4).
class UserMenuActionItem {
  final String buttonName;
  final String executionPath;

  const UserMenuActionItem({
    required this.buttonName,
    required this.executionPath,
  });

  Map<String, dynamic> toJson() => {
        'buttonName': buttonName,
        'executionPath': executionPath,
      };

  factory UserMenuActionItem.fromJson(Map<String, dynamic> j) {
    return UserMenuActionItem(
      buttonName: '${j['buttonName'] ?? j['name'] ?? ''}',
      executionPath: '${j['executionPath'] ?? j['path'] ?? ''}',
    );
  }

  UserMenuActionItem copyWith({
    String? buttonName,
    String? executionPath,
  }) {
    return UserMenuActionItem(
      buttonName: buttonName ?? this.buttonName,
      executionPath: executionPath ?? this.executionPath,
    );
  }
}

class UserMenuCategory {
  final String title;
  final List<UserMenuActionItem> actions;

  const UserMenuCategory({
    required this.title,
    this.actions = const [],
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'actions': actions.map((e) => e.toJson()).toList(),
      };

  factory UserMenuCategory.fromJson(Map<String, dynamic> j) {
    final raw = j['actions'] ?? j['items'];
    final list = <UserMenuActionItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        list.add(UserMenuActionItem.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return UserMenuCategory(
      title: '${j['title'] ?? ''}',
      actions: list,
    );
  }

  UserMenuCategory copyWith({
    String? title,
    List<UserMenuActionItem>? actions,
  }) {
    return UserMenuCategory(
      title: title ?? this.title,
      actions: actions ?? this.actions,
    );
  }
}

/// Root document stored as JSON / sent to [saveUserMenuLayout].
class UserMenuLayoutDocument {
  static const int currentVersion = 1;

  final int version;
  final List<UserMenuCategory> categories;

  const UserMenuLayoutDocument({
    this.version = currentVersion,
    this.categories = const [],
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'categories': categories.map((e) => e.toJson()).toList(),
      };

  factory UserMenuLayoutDocument.fromJson(Map<String, dynamic> j) {
    final raw = j['categories'];
    final list = <UserMenuCategory>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        list.add(UserMenuCategory.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return UserMenuLayoutDocument(
      version: j['version'] is int ? j['version'] as int : currentVersion,
      categories: list,
    );
  }

  factory UserMenuLayoutDocument.empty() =>
      const UserMenuLayoutDocument(categories: []);
}
