import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'wind_service.dart';

const bg = Color(0xFF071320);
const surface = Color(0xFF102238);
const line = Color(0xFF263B51);
const mint = Color(0xFF56DFD6);
const muted = Color(0xFF9EB3C9);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WindApp());
}

class WindApp extends StatelessWidget {
  const WindApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Oman Wind Explorer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(primary: mint, surface: surface),
        inputDecorationTheme: InputDecorationTheme(
          filled: true, fillColor: const Color(0xFF162D42),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
        ),
      ),
      home: const Directionality(textDirection: TextDirection.rtl, child: WindHome()),
    );
  }
}

class WindHome extends StatefulWidget {
  const WindHome({super.key});
  @override
  State<WindHome> createState() => _WindHomeState();
}

class _WindHomeState extends State<WindHome> {
  final service = WindService();
  final latController = TextEditingController();
  final lonController = TextEditingController();
  List<Wilayat> wilayats = [];
  List<WindReading> readings = [];
  String governorate = 'الداخلية';
  String? selectedId;
  String? error;
  String status = 'جاري تجهيز قائمة الولايات...';
  String coordinatesLabel = '—';
  String displayLocation = 'نزوى';
  DateTime endDate = DateTime.now().toUtc().subtract(const Duration(days: 1));
  bool isLoading = false;
  bool manualCoordinates = false;
  int runId = 0;

  @override
  void initState() {
    super.initState();
    _initialise();
  }

  Future<void> _initialise() async {
    try {
      final raw = await rootBundle.loadString('assets/wilayats.json');
      final list = (jsonDecode(raw) as List)
          .map((e) => Wilayat.fromJson(e as Map<String, dynamic>)).toList();
      if (list.length != 63) throw Exception('Expected 63 wilayats');
      if (!mounted) return;
      setState(() {
        wilayats = list;
        selectedId = list.firstWhere((p) => p.ar == 'نزوى').id;
        status = 'جاهز لطلب بيانات NASA POWER';
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = 'تعذر قراءة قائمة الولايات: $e');
    }
  }

  Wilayat? get selected {
    for (final p in wilayats) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  Future<void> _load() async {
    final p = selected;
    if (p == null && !manualCoordinates) return;
    final currentId = ++runId;
    setState(() {
      isLoading = true;
      error = null;
      readings = [];
      status = 'جاري تحميل بيانات NASA...';
    });
    try {
      late final WindLocation loc;
      if (manualCoordinates) {
        final lat = double.tryParse(latController.text.trim());
        final lon = double.tryParse(lonController.text.trim());
        if (lat == null || lon == null || !validCoordinates(lat, lon)) {
          throw Exception('أدخل Latitude وLongitude صحيحين أولاً.');
        }
        loc = WindLocation(lat, lon, 'إحداثيات مخصصة');
      } else {
        loc = await service.locationFor(p!);
      }
      if (!mounted || currentId != runId) return;
      final rows = await service.fetchWind(loc.lat, loc.lon, endDate);
      if (!mounted || currentId != runId) return;
      setState(() {
        readings = rows;
        displayLocation = manualCoordinates ? 'إحداثيات مخصصة' : p!.ar;
        coordinatesLabel = '${loc.lat.toStringAsFixed(4)}°, ${loc.lon.toStringAsFixed(4)}°';
        status = '${rows.length} قراءات من NASA POWER · ${loc.source}';
      });
    } catch (e) {
      if (!mounted || currentId != runId) return;
      setState(() {
        error = e.toString().replaceFirst('Exception: ', '');
        status = 'تعذر تحميل البيانات';
      });
    } finally {
      if (mounted && currentId == runId) setState(() => isLoading = false);
    }
  }

  @override
  void dispose() {
    service.dispose();
    latController.dispose();
    lonController.dispose();
    super.dispose();
  }

  Future<void> _changeDate() async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(1981),
      lastDate: DateTime(yesterday.year, yesterday.month, yesterday.day),
      initialDate: endDate.isAfter(yesterday) ? yesterday : endDate,
    );
    if (picked != null && mounted) {
      setState(() => endDate = picked);
      await _load();
    }
  }

  Widget _panel({required Widget child, EdgeInsets? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: line),
        ),
        child: child,
      );

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(text, style: const TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  Widget _governorateDropdown() {
    final governors = wilayats.map((e) => e.governorateAr).toSet().toList();
    return DropdownButtonFormField<String>(
      key: ValueKey('gov-$governorate'),
      initialValue: governors.contains(governorate) ? governorate : null,
      isExpanded: true,
      items: governors.map((p) => DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: isLoading ? null : (v) {
        if (v == null) return;
        setState(() {
          governorate = v;
          selectedId = wilayats.firstWhere((p) => p.governorateAr == v).id;
          manualCoordinates = false;
          readings = [];
          error = null;
        });
      },
    );
  }

  Widget _wilayatDropdown() {
    final list = wilayats.where((p) => p.governorateAr == governorate).toList();
    return DropdownButtonFormField<String>(
      key: ValueKey('wil-$governorate-$selectedId'),
      initialValue: list.any((p) => p.id == selectedId) ? selectedId : null,
      isExpanded: true,
      items: list.map((p) => DropdownMenuItem(value: p.id, child: Text(p.ar, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: isLoading ? null : (v) {
        setState(() {
          selectedId = v;
          manualCoordinates = false;
          readings = [];
          error = null;
        });
      },
    );
  }

  Widget _controls() => _panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Row(children: [Icon(Icons.place_outlined, color: mint, size: 19), SizedBox(width: 7), Text('حدد موقعك', style: TextStyle(fontWeight: FontWeight.w800)), Spacer(), Text('63 ولاية', style: TextStyle(color: muted, fontSize: 11))]),
          const SizedBox(height: 18),
          _label('المحافظة'),
          _governorateDropdown(),
          const SizedBox(height: 13),
          _label('الولاية'),
          _wilayatDropdown(),
          const SizedBox(height: 13),
          _label('تاريخ النهاية'),
          OutlinedButton.icon(
            onPressed: isLoading ? null : _changeDate,
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            label: Text('${endDate.day.toString().padLeft(2, '0')}/${endDate.month.toString().padLeft(2, '0')}/${endDate.year}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(49), foregroundColor: Colors.white, side: const BorderSide(color: line)),
          ),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('استخدام إحداثيات يدوية', style: TextStyle(fontSize: 12)),
            value: manualCoordinates,
            activeTrackColor: mint,
            onChanged: isLoading ? null : (v) => setState(() { manualCoordinates = v; readings = []; error = null; }),
          ),
          if (manualCoordinates) ...[
            const SizedBox(height: 9),
            TextField(controller: latController, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Latitude', hintText: '23.84944')),
            const SizedBox(height: 10),
            TextField(controller: lonController, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: const InputDecoration(labelText: 'Longitude', hintText: '57.43861')),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: isLoading || wilayats.isEmpty ? null : _load,
            icon: isLoading ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: bg)) : const Icon(Icons.arrow_outward),
            label: Text(isLoading ? 'يتم تحميل البيانات...' : 'عرض بيانات الرياح'),
            style: FilledButton.styleFrom(backgroundColor: mint, foregroundColor: const Color(0xFF083237), minimumSize: const Size.fromHeight(49), textStyle: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
      );

  Widget _windHero() {
    final latest = readings.isEmpty ? null : readings.last;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF164F55), Color(0xFF0D3545)], begin: Alignment.topRight, end: Alignment.bottomLeft),
        border: Border.all(color: const Color(0xFF39777B)),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Expanded(child: Text('متوسط سرعة الرياح اليومي', style: TextStyle(fontSize: 12, color: Color(0xFFBDEFE8), fontWeight: FontWeight.w700))), Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(borderRadius: BorderRadius.circular(30), border: Border.all(color: const Color(0xFF4B8E89))), child: const Text('WS2M · 2m', style: TextStyle(fontSize: 10, color: Color(0xFFB7F1E4))))]),
        const SizedBox(height: 12),
        const Align(alignment: Alignment.centerRight, child: Icon(Icons.air, size: 58, color: Color(0xFF9DE6DC))),
        const SizedBox(height: 8),
        Directionality(textDirection: TextDirection.ltr, child: Row(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(latest == null ? '--' : latest.ms.toStringAsFixed(2), style: const TextStyle(fontSize: 65, fontWeight: FontWeight.w900, letterSpacing: -2, height: 1.1)),
          const SizedBox(width: 9), const Text('m/s', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFFC1EEE7))),
        ])),
        const SizedBox(height: 15),
        const Divider(color: Color(0xFF3B7778)),
        Row(children: [Expanded(child: Text(latest == null ? 'بانتظار NASA' : 'التاريخ: ${formatDay(latest.day)}', style: const TextStyle(fontSize: 11, color: Color(0xFFBEDED9)))), Text(displayLocation, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))]),
      ]),
    );
  }

  Widget _stat(String label, String value, String caption, IconData icon) => Expanded(
        child: _panel(
          padding: const EdgeInsets.all(15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: mint, size: 24), const SizedBox(height: 10),
            Text(label, style: const TextStyle(fontSize: 11, color: muted)),
            const SizedBox(height: 8),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text('$value m/s', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 23))),
            Text(caption, style: const TextStyle(color: Color(0xFF6E95A6), fontSize: 10)),
          ]),
        ),
      );

  Widget _results() {
    final speeds = readings.map((e) => e.ms).toList();
    final avg = speeds.isEmpty ? '--' : (speeds.reduce((a, b) => a + b) / speeds.length).toStringAsFixed(2);
    final maxVal = speeds.isEmpty ? '--' : speeds.reduce(math.max).toStringAsFixed(2);
    return Column(children: [
      _windHero(),
      const SizedBox(height: 13),
      Row(children: [
        _stat('متوسط 7 أيام', avg, '7-day average', Icons.insights),
        const SizedBox(width: 11),
        _stat('أعلى قيمة', maxVal, '7-day maximum', Icons.trending_up),
      ]),
    ]);
  }

  Widget _history() => _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('HISTORICAL DATA', style: TextStyle(color: mint, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
    const SizedBox(height: 8),
    const Text('تغير سرعة الرياح', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
    const SizedBox(height: 4),
    const Text('آخر 7 أيام متاحة · WS2M', style: TextStyle(fontSize: 12, color: muted)),
    const SizedBox(height: 14),
    if (readings.isEmpty)
      const SizedBox(height: 200, child: Center(child: Text('سيظهر الرسم البياني بعد تحميل البيانات', style: TextStyle(color: muted, fontSize: 12))))
    else
      SizedBox(height: 220, child: CustomPaint(painter: WindChartPainter(readings), child: const SizedBox.expand())),
    const SizedBox(height: 12), const Divider(color: line),
    Text('NASA POWER · $coordinatesLabel', style: const TextStyle(color: muted, fontSize: 11)),
  ]));

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: SafeArea(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18), children: [
      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 960), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFF17464E), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.air, color: mint, size: 25)), const SizedBox(width: 11), const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('OMAN WIND', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.6)), Text('EXPLORER · NASA POWER', style: TextStyle(fontSize: 10, color: muted, letterSpacing: .8))])), const Icon(Icons.public, color: muted)]),
        const SizedBox(height: 30),
        const Text('WIND INTELLIGENCE · OMAN', style: TextStyle(color: mint, fontSize: 10, letterSpacing: 1.7)),
        const SizedBox(height: 5),
        const Text('استكشف رياح عُمان', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
        const SizedBox(height: 7),
        const Text('متوسط سرعة الرياح اليومي من بيانات NASA POWER', style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 22),
        LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth > 700;
          final controls = _controls();
          final result = _results();
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 4, child: controls), const SizedBox(width: 15), Expanded(flex: 5, child: result)])
              : Column(children: [controls, const SizedBox(height: 15), result]);
        }),
        const SizedBox(height: 12),
        _panel(padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14), child: Row(children: [Icon(error != null ? Icons.error_outline : isLoading ? Icons.sync : Icons.check_circle_outline, color: error != null ? const Color(0xFFFFB6BA) : mint), const SizedBox(width: 10), Expanded(child: Text(error ?? status, style: const TextStyle(fontSize: 12, height: 1.7)))])),
        const SizedBox(height: 15),
        _history(),
        const SizedBox(height: 14),
        _panel(child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.info_outline, color: mint), SizedBox(width: 12), Expanded(child: Text('WS2M هو متوسط سرعة الرياح اليومي المُقدّر عند ارتفاع مترين في نقطة جغرافية محددة، وليس قياساً لحظياً أو تحذيراً جوياً. بعض مواقع الولايات تُحدّد تقريبياً من OpenStreetMap عند طلبها.', style: TextStyle(fontSize: 12, height: 1.8, color: muted)))])),
        const SizedBox(height: 16),
        const Center(child: Text('DATA: NASA POWER · LOCATIONS: © OpenStreetMap contributors', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: muted))),
        const SizedBox(height: 25),
      ]))),
    ])));
  }
}

class WindChartPainter extends CustomPainter {
  final List<WindReading> readings;
  const WindChartPainter(this.readings);
  @override
  void paint(Canvas canvas, Size size) {
    if (readings.isEmpty) return;
    const left = 39.0, right = 15.0, top = 22.0, bottom = 36.0;
    final plotW = math.max(1.0, size.width - left - right);
    final plotH = math.max(1.0, size.height - top - bottom);
    final high = readings.fold<double>(1, (m, r) => math.max(m, r.ms));
    final maxY = (high * 1.2 * 2).ceilToDouble() / 2;
    final grid = Paint()..color = const Color(0xFF284055)..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = top + plotH * i / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      _text(canvas, (maxY * (1 - i / 4)).toStringAsFixed(1), Offset(0, y - 7), 10, muted);
    }
    Offset point(int i) {
      final x = left + plotW * (readings.length == 1 ? .5 : i / (readings.length - 1));
      return Offset(x, top + plotH - (readings[i].ms / maxY) * plotH);
    }
    final path = Path();
    for (var i = 0; i < readings.length; i++) {
      final p = point(i);
      if (i == 0) {path.moveTo(p.dx, p.dy);} else {path.lineTo(p.dx, p.dy);}
    }
    final fill = Path.from(path);
    fill.lineTo(point(readings.length - 1).dx, top + plotH);
    fill.lineTo(point(0).dx, top + plotH);
    fill.close();
    canvas.drawPath(fill, Paint()..color = mint.withValues(alpha: .11));
    canvas.drawPath(path, Paint()..color = mint..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
    for (var i = 0; i < readings.length; i++) {
      final p = point(i);
      canvas.drawCircle(p, 4, Paint()..color = mint);
      canvas.drawCircle(p, 2, Paint()..color = const Color(0xFF0E2D39));
      final date = readings[i].day;
      _text(canvas, '${date.substring(6, 8)}/${date.substring(4, 6)}', Offset(p.dx - 13, size.height - 23), 9, muted);
    }
  }
  void _text(Canvas canvas, String text, Offset at, double size, Color color) {
    final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(fontSize: size, color: color)), textDirection: TextDirection.ltr)..layout();
    painter.paint(canvas, at);
  }
  @override
  bool shouldRepaint(covariant WindChartPainter oldDelegate) => oldDelegate.readings != readings;
}
