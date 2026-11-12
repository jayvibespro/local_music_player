import '../models/track.dart';
import 'play_history.dart';

enum StatsPeriod {
  week('Week', 7),
  month('Month', 30),
  year('Year', 365),
  all('All time', null);

  const StatsPeriod(this.label, this.days);
  final String label;
  final int? days;

  DateTime? since(DateTime now) => days == null
      ? null
      : DateTime(now.year, now.month, now.day - (days! - 1));
}

typedef Ranked<T> = ({T item, int plays});

/// One bar in the listening chart: a day (week/month) or a month (year/all).
typedef ListeningBucket = ({DateTime start, String label, Duration time});

class ListeningStats {
  const ListeningStats({
    required this.period,
    required this.totalTime,
    required this.plays,
    required this.distinctSongs,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.buckets,
    required this.peakHour,
  });

  final StatsPeriod period;
  final Duration totalTime;
  final int plays;
  final int distinctSongs;
  final List<Ranked<Track>> topTracks;

  /// Artist name, with the tracks for artwork.
  final List<Ranked<String>> topArtists;
  final List<Ranked<String>> topAlbums;
  final List<ListeningBucket> buckets;

  /// Hour of day (0-23) with the most plays, or null without data.
  final int? peakHour;

  bool get isEmpty => plays == 0 && totalTime == Duration.zero;
}

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

ListeningStats computeStats(
  PlayHistory history,
  Track? Function(String id) trackById,
  StatsPeriod period, {
  DateTime? now,
  int top = 10,
}) {
  now ??= DateTime.now();
  final since = period.since(now);
  final events = history.playsSince(since).toList();

  final trackPlays = <String, int>{};
  final artistPlays = <String, int>{};
  final albumPlays = <String, int>{};
  final hours = List<int>.filled(24, 0);
  for (final e in events) {
    hours[e.at.hour]++;
    final track = trackById(e.trackId);
    if (track == null) continue; // deleted or hidden since
    trackPlays.update(track.id, (v) => v + 1, ifAbsent: () => 1);
    artistPlays.update(track.artist, (v) => v + 1, ifAbsent: () => 1);
    if (track.album != Track.unknownAlbum) {
      albumPlays.update(track.album, (v) => v + 1, ifAbsent: () => 1);
    }
  }

  List<Ranked<T>> rank<T>(Map<T, int> counts) {
    final list = [
      for (final MapEntry(:key, :value) in counts.entries)
        (item: key, plays: value),
    ]..sort((a, b) => b.plays.compareTo(a.plays));
    return list.take(top).toList();
  }

  var peak = -1;
  for (var h = 0; h < 24; h++) {
    if (hours[h] > 0 && (peak < 0 || hours[h] > hours[peak])) peak = h;
  }

  return ListeningStats(
    period: period,
    totalTime: history.listeningSince(since),
    plays: events.length,
    distinctSongs: trackPlays.length,
    topTracks: [
      for (final r in rank(trackPlays))
        (item: trackById(r.item)!, plays: r.plays),
    ],
    topArtists: rank(artistPlays),
    topAlbums: rank(albumPlays),
    buckets: _buckets(history, period, now),
    peakHour: peak < 0 ? null : peak,
  );
}

List<ListeningBucket> _buckets(
  PlayHistory history,
  StatsPeriod period,
  DateTime now,
) {
  switch (period) {
    case StatsPeriod.week:
    case StatsPeriod.month:
      final daily = history.dailyListening(period.since(now)!);
      return [
        for (final MapEntry(key: day, value: time) in daily.entries)
          (
            start: day,
            label: period == StatsPeriod.week
                ? _dayNames[day.weekday - 1]
                : '${day.day}',
            time: time,
          ),
      ];
    case StatsPeriod.year:
    case StatsPeriod.all:
      // Monthly totals; "all" shows the last 12 months too.
      final first = DateTime(now.year, now.month - 11);
      final daily = history.dailyListening(first);
      final months = <DateTime, Duration>{
        for (var i = 0; i < 12; i++)
          DateTime(first.year, first.month + i): Duration.zero,
      };
      daily.forEach((day, time) {
        final key = DateTime(day.year, day.month);
        months[key] = (months[key] ?? Duration.zero) + time;
      });
      return [
        for (final MapEntry(key: m, value: time) in months.entries)
          (start: m, label: _monthNames[m.month - 1], time: time),
      ];
  }
}

/// "3 h 12 min", "45 min", "0 min".
String formatListening(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// "8 PM", "12 AM".
String formatHour(int hour) {
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h ${hour < 12 ? 'AM' : 'PM'}';
}
