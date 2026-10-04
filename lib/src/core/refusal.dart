class Refusal implements Exception {
  final String message;
  const Refusal(this.message);
  @override
  String toString() => message;
}

num number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const Refusal('Missing or invalid numeric API field.');
  }
  return value;
}
