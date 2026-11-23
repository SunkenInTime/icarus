abstract interface class StoreSessions {
  Future<bool> sessionOn(String strategyId, int connection);

  void addedOn(String strategyId, int connection);
}
