class SmartAlert {
  final String id;
  final String title;
  final String description;
  final DateTime timestamp;
  final AlertSeverity severity;

  const SmartAlert({
    required this.id,
    required this.title,
    required this.description,
    required this.timestamp,
    this.severity = AlertSeverity.info,
  });
}

enum AlertSeverity { info, warning, critical }
