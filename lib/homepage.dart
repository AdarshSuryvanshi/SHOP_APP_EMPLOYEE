import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:employee/availability_api.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? employeeId; // phone as id
  String? employeeName;

  DateTime today = DateTime.now();

  // Per-day enable and slot lists
  final Map<DateTime, bool> _dayEnabled = {};
  final Map<DateTime, List<_TimeRange>> _slots = {};
  final Map<DateTime, _DayCheckStatus> _dayCheck = {}; // API status

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadEmployee();
    _initWeekMondayFirst();
    await _hydrateFromStorage();
    if (mounted) setState(() {});
  }

  Future<void> _loadEmployee() async {
    final prefs = await SharedPreferences.getInstance();
    employeeId = prefs.getString('phone');
    employeeName = prefs.getString('name');
  }

  // Find the upcoming Monday (today if Monday)
  DateTime _upcomingMonday(DateTime d) {
    final base = _dayOnly(d);
    final add = (DateTime.monday - base.weekday) % 7;
    return base.add(Duration(days: add));
  }

  void _initWeekMondayFirst() {
    final base = _upcomingMonday(today);
    for (int i = 0; i < 7; i++) {
      final d = base.add(Duration(days: i));
      _dayEnabled[d] = false;
      _slots[d] = <_TimeRange>[];
      _dayCheck[d] = _DayCheckStatus.none;
    }
  }

  DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  // Rehydrate local state from availability_v2 if present
  Future<void> _hydrateFromStorage() async {
    if (employeeId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('availability_v2') ?? '{}';
    final all = jsonDecode(raw) as Map<String, dynamic>;
    final emp = all[employeeId!] as Map<String, dynamic>?;
    if (emp == null) return;

    final base = _upcomingMonday(today);
    for (int i = 0; i < 7; i++) {
      final day = base.add(Duration(days: i));
      final dateStr = _fmtDate(day);
      final rec = emp[dateStr] as Map<String, dynamic>?;
      if (rec == null) {
        _dayEnabled[day] = false;
        _slots[day] = <_TimeRange>[];
      } else {
        _dayEnabled[day] = true;
        final list = (rec['slots'] as List<dynamic>? ?? []);
        _slots[day] = list.map((m) {
          final mm = m as Map<String, dynamic>;
          return _TimeRange.fromMinutes(mm['startMinutes'] as int, mm['endMinutes'] as int);
        }).toList()
          ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
      }
    }
  }

  // Labels and formatting
  static const _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String _weekdayLabel(DateTime d) => _weekdayShort[d.weekday - 1];
  String _fmtDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _fmtHuman(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  String _fmtHm(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<TimeOfDay?> _pickTime24h(TimeOfDay initial) {
    return showTimePicker(
      context: context,
      initialTime: initial,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
  }

  Future<void> _addSlot(DateTime day) async {
    // Auto-enable when adding first slot
    if (!(_dayEnabled[day] ?? false)) {
      setState(() => _dayEnabled[day] = true);
    }

    final start = await _pickTime24h(TimeOfDay.now());
    if (start == null) return;
    final end = await _pickTime24h(start);
    if (end == null) return;

    final startM = _toMinutes(day, start);
    final endM = _toMinutes(day, end);
    if (endM <= startM) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('End must be after start')));
      return;
    }
    // Overlap prevention; adjacent allowed
    final newRange = _TimeRange(startMinutes: startM, endMinutes: endM);
    final list = List<_TimeRange>.from(_slots[day] ?? []);
    final overlaps = list.any((r) => r.overlaps(newRange));
    if (overlaps) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Slots cannot overlap')));
      return;
    }
    list.add(newRange);
    list.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    setState(() => _slots[day] = list);
  }

  void _removeSlot(DateTime day, int index) {
    final list = List<_TimeRange>.from(_slots[day] ?? []);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    setState(() {
      _slots[day] = list;
      if (list.isEmpty) _dayEnabled[day] = false;
    });
  }

  int _toMinutes(DateTime date, TimeOfDay t) =>
      DateTime(date.year, date.month, date.day, t.hour, t.minute)
          .difference(DateTime(date.year, date.month, date.day))
          .inMinutes;

  // Persist availability_v2 and derived Mon–Sun summary
  Future<void> _saveAvailability() async {
    if (employeeId == null) return;
    final prefs = await SharedPreferences.getInstance();

    final Map<String, dynamic> availability =
        jsonDecode(prefs.getString('availability_v2') ?? '{}') as Map<String, dynamic>;

    final base = _upcomingMonday(today);
    final Map<String, dynamic> empMap = {};

    for (int i = 0; i < 7; i++) {
      final day = base.add(Duration(days: i));
      final dateStr = _fmtDate(day);
      final enabled = _dayEnabled[day] ?? false;
      final list = _slots[day] ?? <_TimeRange>[];

      if (enabled && list.isNotEmpty) {
        empMap[dateStr] = {
          'slots': list
              .map((r) => {
                    'startMinutes': r.startMinutes,
                    'endMinutes': r.endMinutes,
                    'employeeName': employeeName ?? '',
                  })
              .toList(),
        };
      }
    }

    availability[employeeId!] = empMap;
    await prefs.setString('availability_v2', jsonEncode(availability));

    // Derived Mon→Sun summary using earliest start / latest end
    final Map<String, dynamic> summary = {};
    for (int i = 0; i < 7; i++) {
      final day = base.add(Duration(days: i));
      final dateStr = _fmtDate(day);
      final short = _weekdayLabel(day);
      final rec = empMap[dateStr] as Map<String, dynamic>?;
      if (rec == null) {
        summary[short] = null;
      } else {
        final list = (rec['slots'] as List).cast<Map<String, dynamic>>();
        final startMin = list.map((m) => m['startMinutes'] as int).reduce((a, b) => a < b ? a : b);
        final endMin = list.map((m) => m['endMinutes'] as int).reduce((a, b) => a > b ? a : b);
        summary[short] = {'start': _fmtHm(startMin), 'end': _fmtHm(endMin)};
      }
    }
    await prefs.setString('weekly_day_summary_v1', jsonEncode(summary));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Availability saved')));

    // Run availability checker after successful save
    await _runAvailabilityCheck(base);

    setState(() {});
  }

  // Build DTO for API
  Map<String, dynamic> _buildAvailabilityPayload(DateTime weekStart) {
    final tzOffset = DateTime.now().timeZoneOffset.inMinutes;
    final days = <Map<String, dynamic>>[];
    for (int i = 0; i < 7; i++) {
      final d = weekStart.add(Duration(days: i));
      final dateStr = _fmtDate(d);
      final enabled = _dayEnabled[d] ?? false;
      final ranges = _slots[d] ?? const <_TimeRange>[];
      days.add({
        'date': dateStr,
        'enabled': enabled && ranges.isNotEmpty,
        'slots': ranges.map((r) => {'startMinutes': r.startMinutes, 'endMinutes': r.endMinutes}).toList(),
      });
    }
    return {
      'employeeId': employeeId,
      'employeeName': employeeName,
      'weekStart': _fmtDate(weekStart),
      'timezoneOffsetMinutes': tzOffset,
      'days': days,
    };
  }

  Future<void> _runAvailabilityCheck(DateTime weekStart) async {
    final payload = _buildAvailabilityPayload(weekStart);
    final api = AvailabilityApi(
      baseUrl: 'https://techmaharajas.onrender.com', // TODO: set your base URL
      checkPath: '/api/availability/save',   // TODO: confirm endpoint
      timeoutMs: 12000,
      maxRetries: 3,
      // authToken: '...', // if required
    );

    // Default dots to grey
    for (int i = 0; i < 7; i++) {
      final d = weekStart.add(Duration(days: i));
      _dayCheck[d] = _DayCheckStatus.none;
    }
    setState(() {});

    final res = await api.checkAvailability(payload);

    if (res.status == AvailabilityCheckStatus.ok || res.status == AvailabilityCheckStatus.validation) {
      final perDay = (res.data?['perDay'] as Map?) ?? {};
      for (int i = 0; i < 7; i++) {
        final d = weekStart.add(Duration(days: i));
        final k = _fmtDate(d);
        final v = (perDay[k] ?? (res.status == AvailabilityCheckStatus.ok ? 'ok' : 'error')).toString();
        _dayCheck[d] = v == 'ok' ? _DayCheckStatus.ok : v == 'warn' ? _DayCheckStatus.warn : _DayCheckStatus.error;
      }
      if (mounted && (res.data?['message'] is String)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res.data!['message'] as String)));
      }
    } else if (res.status == AvailabilityCheckStatus.offline) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No internet. Will try later.')));
      }
    } else if (res.status == AvailabilityCheckStatus.network) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error: ${res.message}')));
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Server error ${res.code ?? ''}')));
      }
    }

    if (mounted) setState(() {});
  }

  // Fair schedule across 1-hour slots reading multi-slot availability
  Future<void> _generateSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> availability =
        jsonDecode(prefs.getString('availability_v2') ?? '{}') as Map<String, dynamic>;
    final Map<String, dynamic> schedule =
        jsonDecode(prefs.getString('schedule_v1') ?? '{}') as Map<String, dynamic>;

    final base = _upcomingMonday(today);

    for (int di = 0; di < 7; di++) {
      final day = base.add(Duration(days: di));
      final dateStr = _fmtDate(day);

      final List<_Window> windows = [];
      availability.forEach((empId, byDate) {
        final map = byDate as Map<String, dynamic>;
        final rec = map[dateStr] as Map<String, dynamic>?;
        if (rec == null) return;
        final list = (rec['slots'] as List<dynamic>? ?? []);
        for (final m in list) {
          final mm = m as Map<String, dynamic>;
          final s = (mm['startMinutes'] as num).toInt();
          final e = (mm['endMinutes'] as num).toInt();
          if (e > s) {
            windows.add(_Window(
              employeeId: empId,
              employeeName: (mm['employeeName'] as String?) ?? empId,
              startMinutes: s,
              endMinutes: e,
            ));
          }
        }
      });

      schedule.remove(dateStr);
      if (windows.isEmpty) continue;

      final earliest = windows.map((w) => w.startMinutes).reduce((a, b) => a < b ? a : b);
      final latest = windows.map((w) => w.endMinutes).reduce((a, b) => a > b ? a : b);
      int startHour = earliest ~/ 60;
      int endHour = (latest + 59) ~/ 60;

      final Map<String, int> assignedHours = {for (final w in windows) w.employeeId: 0};
      final List<Map<String, dynamic>> daySlots = [];

      for (int hour = startHour; hour < endHour; hour++) {
        final slotStart = hour * 60;
        final slotEnd = (hour + 1) * 60;

        final available = windows
            .where((w) => w.startMinutes <= slotStart && w.endMinutes >= slotEnd)
            .toList();
        if (available.isEmpty) continue;

        available.sort((a, b) {
          final aa = assignedHours[a.employeeId] ?? 0;
          final bb = assignedHours[b.employeeId] ?? 0;
          if (aa != bb) return aa.compareTo(bb);
          return a.employeeId.compareTo(b.employeeId);
        });
        final chosen = available.first;
        assignedHours[chosen.employeeId] = (assignedHours[chosen.employeeId] ?? 0) + 1;

        daySlots.add({'hour': hour, 'employeeId': chosen.employeeId, 'employeeName': chosen.employeeName});
      }

      final participants =
          assignedHours.entries.where((e) => e.value > 0).map((e) => e.key).toList();
      final n = participants.isEmpty ? 1 : participants.length;
      for (final s in daySlots) {
        s['payShare'] = 1.0 / n;
      }

      schedule[dateStr] = daySlots;
    }

    await prefs.setString('schedule_v1', jsonEncode(schedule));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Schedule generated')));
    setState(() {});
  }

  Future<void> _requestLeave(String dateStr, int hour) async {
    if (employeeId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> schedule =
        jsonDecode(prefs.getString('schedule_v1') ?? '{}') as Map<String, dynamic>;
    final daySlots = (schedule[dateStr] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    final idx = daySlots.indexWhere(
      (s) => (s['hour'] as num).toInt() == hour && s['employeeId'] == employeeId,
    );
    if (idx == -1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Slot not found')));
      return;
    }

    daySlots.removeAt(idx);
    schedule[dateStr] = daySlots;
    await prefs.setString('schedule_v1', jsonEncode(schedule));

    await _generateSchedule();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Leave granted and schedule updated')));
  }

  @override
  Widget build(BuildContext context) {
    final base = _upcomingMonday(today);
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: employeeId == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Week starting Monday • ${_fmtDate(base)} → ${_fmtDate(base.add(const Duration(days: 6)))}'),
                  const SizedBox(height: 8),
                  for (int i = 0; i < 7; i++) _dayCard(base.add(Duration(days: i))),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _saveAvailability, child: const Text('Save Availability')),
                  const SizedBox(height: 16),
                  FilledButton.tonal(onPressed: _generateSchedule, child: const Text('Load  Schedule ')),
                  const Divider(height: 32),
                  const Text('My scheduled slots'),
                  const SizedBox(height: 8),
                  _myScheduleList(base),
                ],
              ),
            ),
    );
  }

  Widget _statusDot(_DayCheckStatus s) {
    Color c;
    switch (s) {
      case _DayCheckStatus.ok:
        c = Colors.green;
        break;
      case _DayCheckStatus.warn:
        c = Colors.amber;
        break;
      case _DayCheckStatus.error:
        c = Colors.red;
        break;
      default:
        c = Colors.grey;
    }
    return Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
  }

  Widget _dayCard(DateTime day) {
    final enabled = _dayEnabled[day] ?? false;
    final list = _slots[day] ?? <_TimeRange>[];
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${_weekdayLabel(day)}  •  ${_fmtHuman(day)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                _statusDot(_dayCheck[day] ?? _DayCheckStatus.none),
                const SizedBox(width: 8),
                // Always enabled; auto-enables day in _addSlot if it was off
                IconButton(
                  tooltip: 'Add slot',
                  onPressed: () => _addSlot(day),
                  icon: const Icon(Icons.add_circle_outline),
                ),
                Switch(
                  value: enabled,
                  onChanged: (v) => setState(() {
                    _dayEnabled[day] = v;
                    if (!v) _slots[day] = <_TimeRange>[];
                  }),
                ),
              ],
            ),
            if (enabled)
              Column(
                children: [
                  const SizedBox(height: 8),
                  for (int i = 0; i < list.length; i++)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      leading: const Icon(Icons.schedule),
                      title: Text('${_fmtHuman(day)}  •  ${_fmtHm(list[i].startMinutes)} to ${_fmtHm(list[i].endMinutes)}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _removeSlot(day, i),
                      ),
                    ),
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('No slots yet, tap + to add'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _myScheduleList(DateTime base) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadSchedule(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
        }
        final schedule = snap.data!;
        final List<Widget> cards = [];
        for (int i = 0; i < 7; i++) {
          final dateStr = _fmtDate(base.add(Duration(days: i)));
          final daySlots = (schedule[dateStr] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
          final mySlots = daySlots.where((s) => s['employeeId'] == employeeId).toList();
          if (mySlots.isEmpty) continue;
          cards.add(
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dateStr, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    for (final s in mySlots)
                      Row(
                        children: [
                          Expanded(
                            child: Text('Hour ${s['hour'].toString().padLeft(2, '0')}:00 — payShare ${(s['payShare'] ?? 0).toStringAsFixed(2)}'),
                          ),
                          TextButton(
                            onPressed: () => _requestLeave(dateStr, (s['hour'] as num).toInt()),
                            child: const Text('Request Leave'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        }
        if (cards.isEmpty) {
          return const Text('No schedule yet');
        }
        return Column(children: cards);
      },
    );
  }

  Future<Map<String, dynamic>> _loadSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString('schedule_v1') ?? '{}') as Map<String, dynamic>;
  }
}

enum _DayCheckStatus { none, ok, warn, error }

class _TimeRange {
  final int startMinutes;
  final int endMinutes;
  _TimeRange({required this.startMinutes, required this.endMinutes});
  factory _TimeRange.fromMinutes(int s, int e) => _TimeRange(startMinutes: s, endMinutes: e);
  // Adjacent OK; true overlap is blocked
  bool overlaps(_TimeRange other) => !(endMinutes <= other.startMinutes || other.endMinutes <= startMinutes);
}

class _Window {
  final String employeeId;
  final String employeeName;
  final int startMinutes;
  final int endMinutes;
  _Window({
    required this.employeeId,
    required this.employeeName,
    required this.startMinutes,
    required this.endMinutes,
  });
}
