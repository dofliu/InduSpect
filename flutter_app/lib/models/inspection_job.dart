class InspectionJob {
  final String id;
  final String title;
  final String status;
  final int completedPoints;
  final int totalPoints;
  final String? location;
  final DateTime? dueDate;

  InspectionJob({
    required this.id,
    required this.title,
    required this.status,
    required this.completedPoints,
    required this.totalPoints,
    this.location,
    this.dueDate,
  });

  factory InspectionJob.fromJson(Map<String, dynamic> json) {
    return InspectionJob(
      id: json['id'] as String,
      title: json['title'] as String? ?? '未命名工作',
      status: json['status'] as String? ?? 'pending',
      completedPoints: json['completedPoints'] as int? ?? 0,
      totalPoints: json['totalPoints'] as int? ?? 0,
      location: json['location'] as String?,
      dueDate: json['dueDate'] != null ? DateTime.tryParse(json['dueDate'] as String) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'status': status,
      'completedPoints': completedPoints,
      'totalPoints': totalPoints,
      'location': location,
      'dueDate': dueDate?.toIso8601String(),
    };
  }

  double get progress => totalPoints == 0 ? 0 : completedPoints / totalPoints;

  bool get isCompleted => completedPoints >= totalPoints && totalPoints > 0;
}
