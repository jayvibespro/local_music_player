class Playlist {
  Playlist({required this.id, required this.name, List<String>? trackIds})
    : trackIds = trackIds ?? [];

  final String id;
  String name;
  final List<String> trackIds;

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    trackIds: (json['trackIds'] as List).cast<String>().toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackIds': trackIds,
  };
}
