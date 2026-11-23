final class Account {
  Account(this.subject) {
    if (subject.isEmpty) throw ArgumentError.value(subject, 'subject');
  }

  final String subject;

  @override
  bool operator ==(Object other) =>
      other is Account && other.subject == subject;

  @override
  int get hashCode => subject.hashCode;

  @override
  String toString() => 'Account($subject)';
}

sealed class CloudOwner {
  const CloudOwner();
}

final class OwnedBy extends CloudOwner {
  const OwnedBy(this.account);

  final Account account;

  @override
  bool operator ==(Object other) =>
      other is OwnedBy && other.account == account;

  @override
  int get hashCode => account.hashCode;

  @override
  String toString() => 'OwnedBy(${account.subject})';
}

final class OwnerUnreadable extends CloudOwner {
  const OwnerUnreadable();

  @override
  bool operator ==(Object other) => other is OwnerUnreadable;

  @override
  int get hashCode => (OwnerUnreadable).hashCode;

  @override
  String toString() => 'OwnerUnreadable';
}
