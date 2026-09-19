import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const SmartPsuApp());
}

class SmartPsuApp extends StatelessWidget {
  const SmartPsuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart PSU - HP Doctor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const AutoConnectPage(),
    );
  }
}

// ---------------- UUID (harus sama dengan firmware ESP32) ----------------
final Guid serviceUuid = Guid("12345678-1234-1234-1234-123456789abc");
final Guid dataCharUuid = Guid("12345678-1234-1234-1234-123456789001");
final Guid commandCharUuid = Guid("12345678-1234-1234-1234-123456789002");

const String deviceKeyword = "SmartPSU";
const double NORMAL_MAX_MA_CLIENT = 400.0;

// =========================================================
// HALAMAN AUTO CONNECT
// =========================================================
class AutoConnectPage extends StatefulWidget {
  const AutoConnectPage({super.key});

  @override
  State<AutoConnectPage> createState() => _AutoConnectPageState();
}

class _AutoConnectPageState extends State<AutoConnectPage> {
  bool scanning = true;
  String statusText = 'Meminta izin Bluetooth...';
  bool hasOpened = false;

  StreamSubscription<List<ScanResult>>? scanSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initFlow());
  }

  Future<void> _initFlow() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final granted = statuses.values.every((s) =>
        s == PermissionStatus.granted || s == PermissionStatus.limited);

    if (!granted) {
      setState(() {
        scanning = false;
        statusText = 'Izin Bluetooth belum diberikan.';
      });
      return;
    }

    await _startAutoConnect();
  }

  Future<void> _startAutoConnect() async {
    setState(() {
      scanning = true;
      statusText = 'Mencari perangkat SmartPSU...';
    });

    final completer = Completer<BluetoothDevice?>();
    await scanSub?.cancel();

    scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName;
        if (name.toLowerCase().contains(deviceKeyword.toLowerCase())) {
          if (!completer.isCompleted) {
            completer.complete(result.device);
          }
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      final found = await completer.future.timeout(
        const Duration(seconds: 11),
        onTimeout: () => null,
      );

      await FlutterBluePlus.stopScan();
      await scanSub?.cancel();

      if (found == null) {
        if (!mounted) return;
        setState(() {
          scanning = false;
          statusText = 'SmartPSU tidak ditemukan.\nTekan tombol coba lagi.';
        });
        return;
      }

      if (!mounted) return;

      setState(() {
        statusText = 'Menghubungkan ke ${found.platformName}...';
      });

      await found.connect(timeout: const Duration(seconds: 15), autoConnect: false);

      if (!mounted) return;

      hasOpened = true;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => MonitorPage(device: found)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        scanning = false;
        statusText = 'Gagal terhubung: $e';
      });
    }
  }

  @override
  void dispose() {
    scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Smart PSU - HP Doctor')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (scanning) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(
                  statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ] else ...[
                Text(
                  statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _startAutoConnect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Coba Lagi'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================
// HALAMAN MONITORING REAL-TIME
// =========================================================
class MonitorPage extends StatefulWidget {
  final BluetoothDevice device;
  const MonitorPage({super.key, required this.device});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  BluetoothCharacteristic? dataChar;
  BluetoothCharacteristic? commandChar;

  double voltage = 0;
  double current = 0;
  int status = 0; // 0 normal, 1 short, 2 no-load, 3 cutoff, 4 warning

  final List<FlSpot> currentHistory = [];
  double t = 0;

  StreamSubscription? sub;

  // ---- Untuk analisa kerusakan ----
  DateTime? monitorStartTime;
  DateTime? probeContactTime;
  DateTime? shortDetectedTime;
  int statusChangeCount = 0;
  int lastStatus = -1;
  String diagnosisText = 'Menunggu data...';
  String diagnosisDetail = '';
  List<String> diagnosisSteps = [];
  IconData diagnosisIcon = Icons.hourglass_empty;
  Color diagnosisColor = Colors.grey;

  double peakCurrent = 0;
  DateTime? peakCurrentTime;
  final List<double> recentSamples = [];
  int oscillationScore = 0;

  // ---- Fitur isolasi komponen ----
  final TextEditingController voltageSetController = TextEditingController(text: '4.0');
  double? isolationBaseline;
  final List<Map<String, dynamic>> isolationLog = [];
  final List<String> commonSuspects = [
    'LCD / Layar',
    'Kamera Belakang',
    'Kamera Depan',
    'Konektor Charging / Board Bawah',
    'PA / RF Shield (Sinyal)',
    'Speaker / Vibrator',
    'Tombol Power/Volume (Sub Board)',
    'Backlight / Sensor',
  ];

  static const statusText = {
    0: 'NORMAL',
    1: 'SHORT CIRCUIT TERDETEKSI!',
    2: 'NO LOAD / BOARD MATI',
    3: 'CUT-OFF AKTIF',
    4: 'ARUS TINGGI (WARNING)',
  };

  static const statusColor = {
    0: Colors.green,
    1: Colors.red,
    2: Colors.grey,
    3: Colors.orange,
    4: Colors.amber,
  };

  @override
  void initState() {
    super.initState();
    _discoverServices();
  }

  Future<void> _discoverServices() async {
    List<BluetoothService> services = await widget.device.discoverServices();
    for (var s in services) {
      if (s.uuid == serviceUuid) {
        for (var c in s.characteristics) {
          if (c.uuid == dataCharUuid) {
            dataChar = c;
            await c.setNotifyValue(true);
            sub = c.onValueReceived.listen(_onData);
          } else if (c.uuid == commandCharUuid) {
            commandChar = c;
          }
        }
      }
    }
    monitorStartTime = DateTime.now();
    setState(() {});
  }

  // =========================================================
  // ANALISA KERUSAKAN (rule-based)
  // =========================================================
  void _analyze(int status, double v, double c) {
    if (status != lastStatus) {
      statusChangeCount++;
      lastStatus = status;
    }

    final elapsedSinceStart = monitorStartTime == null
        ? 999.0
        : DateTime.now().difference(monitorStartTime!).inMilliseconds / 1000.0;

    if (probeContactTime == null && c > 5) {
      probeContactTime = DateTime.now();
    }
    final elapsedSinceContact = probeContactTime == null
        ? 999.0
        : DateTime.now().difference(probeContactTime!).inMilliseconds / 1000.0;

    if (c > peakCurrent) {
      peakCurrent = c;
      peakCurrentTime = DateTime.now();
    }

    recentSamples.add(c);
    if (recentSamples.length > 12) recentSamples.removeAt(0);
    oscillationScore = _computeOscillationScore(recentSamples);

    final setV = double.tryParse(voltageSetController.text) ?? v;
    final sagPercent = setV > 0 ? ((setV - v) / setV * 100) : 0;

    diagnosisSteps = [];

    switch (status) {
      case 1:
        shortDetectedTime ??= DateTime.now();
        diagnosisIcon = Icons.warning_amber;
        diagnosisColor = Colors.red;

        if (elapsedSinceContact < 0.5) {
          diagnosisText = 'Short Berat — Langsung Saat Probe Nempel';
          diagnosisDetail = 'Arus langsung melonjak (${c.toStringAsFixed(0)} mA) dalam <0.5 detik. '
              'Ini pola short "keras" (dead short) pada jalur power utama, biasanya sebelum CPU sempat boot.';
          diagnosisSteps = [
            'Cek IC PMIC dan IC charging (paling sering jadi biang short keras)',
            'Cek konektor baterai & jalur BAT+ dari korosi/kontak logam nyangkut',
            'Turunkan tegangan ke 0.5–1V lalu raba komponen yang cepat panas',
            'Jika ada thermal camera, gunakan untuk menemukan titik panas lebih cepat',
          ];
        } else if (elapsedSinceContact < 3.0) {
          diagnosisText = 'Short Muncul Saat Board Mulai Boot';
          diagnosisDetail = 'Arus normal sesaat, lalu melonjak (${c.toStringAsFixed(0)} mA) sekitar '
              '${elapsedSinceContact.toStringAsFixed(1)} detik setelah kontak — bertepatan dengan tahap CPU/baseband mulai aktif.';
          diagnosisSteps = [
            'Curigai IC baseband/modem, PA (power amplifier), atau IC RAM/CPU yang short saat diberi clock',
            'Coba lepas shield RF/baseband lalu tes ulang — jika short hilang, masalah di area itu',
            'Cek juga IC audio dan tristar/charging connector sebagai kandidat kedua',
          ];
        } else {
          diagnosisText = 'Short Setelah Board Berjalan Cukup Lama';
          diagnosisDetail = 'Board sempat menarik arus normal selama ${elapsedSinceContact.toStringAsFixed(1)} detik '
              'sebelum akhirnya short (${c.toStringAsFixed(0)} mA). Pola ini khas komponen yang gagal saat panas/dibebani.';
          diagnosisSteps = [
            'Curigai elco/kapasitor yang bocor, atau IC power yang rusak akibat panas (thermal-dependent short)',
            'Coba beri jeda pendinginan lalu tes ulang — jika short baru muncul lagi setelah delay serupa, kemungkinan komponen tsb',
            'Cek juga baterai lama/IC charging jika HP sebelumnya sering panas',
          ];
        }
        diagnosisDetail += ' Output sudah dipotong otomatis untuk mencegah kerusakan lebih lanjut.';
        break;

      case 2:
        diagnosisIcon = Icons.power_off;
        diagnosisColor = Colors.grey;
        if (sagPercent.abs() < 5) {
          diagnosisText = 'Tidak Ada Konsumsi Arus Sama Sekali';
          diagnosisDetail = 'Tegangan stabil di ${v.toStringAsFixed(2)} V (sesuai setting) tapi arus nyaris 0. '
              'Board benar-benar tidak menarik daya.';
          diagnosisSteps = [
            'Cek dulu apakah probe benar-benar menempel ke titik BAT+/BAT- (paling sering jadi false alarm)',
            'Cek sekring (fuse) dekat konektor baterai dengan multimeter mode kontinuitas',
            'Jika fuse OK, curigai IC PMIC utama mati total atau jalur BAT+ putus di dalam board',
          ];
        } else {
          diagnosisText = 'Tidak Ada Arus, Tegangan Terlihat Turun (Sag)';
          diagnosisDetail = 'Tegangan yang terbaca (${v.toStringAsFixed(2)} V) lebih rendah dari setting '
              '(${setV.toStringAsFixed(2)} V), sekitar ${sagPercent.toStringAsFixed(0)}% drop, meski arus dianggap ~0. '
              'Ini bisa menandakan resistansi kontak tinggi di probe/konektor.';
          diagnosisSteps = [
            'Perbaiki kontak probe ke pad baterai (bersihkan pad dari oksidasi)',
            'Pastikan kabel probe cukup besar (bukan kabel tipis) agar tidak drop tegangan sendiri',
          ];
        }
        break;

      case 4:
        diagnosisIcon = Icons.thermostat;
        diagnosisColor = Colors.amber;
        diagnosisText = 'Konsumsi Arus di Atas Normal';
        diagnosisDetail = 'Arus di ${c.toStringAsFixed(0)} mA, di atas normal tapi belum mencapai batas short '
            '(puncak sejauh ini ${peakCurrent.toStringAsFixed(0)} mA).';
        diagnosisSteps = [
          'Perhatikan apakah HP terasa hangat/panas di area tertentu — itu petunjuk lokasi masalah',
          'Curigai modul kamera, RF/PA, atau backlight LCD yang menarik arus berlebih',
          'Jika arus terus naik pelan, kemungkinan menuju short — siapkan untuk cut-off manual',
        ];
        break;

      case 3:
        diagnosisIcon = Icons.block;
        diagnosisColor = Colors.orange;
        diagnosisText = 'Output Dimatikan (Proteksi Aktif)';
        diagnosisDetail = 'Proteksi aktif (otomatis karena short, atau ditekan manual).';
        diagnosisSteps = [
          'Periksa/lepas komponen yang dicurigai (lihat riwayat status sebelum cutoff)',
          'Tekan "Reset / Nyalakan" untuk mencoba lagi setelah pemeriksaan',
        ];
        break;

      default:
        if (oscillationScore >= 6) {
          diagnosisIcon = Icons.blur_on;
          diagnosisColor = Colors.cyan;
          diagnosisText = 'Pembacaan Arus Tidak Stabil / Noise Tinggi';
          diagnosisDetail = 'Arus naik-turun cepat dan tidak beraturan (skor osilasi $oscillationScore/10), '
              'bukan pola boot yang halus. Ini sering menandakan masalah kontak, bukan murni kerusakan komponen.';
          diagnosisSteps = [
            'Curigai korosi/kontak longgar di board — cek bekas air/oksidasi di sekitar konektor baterai',
            'Cek juga apakah probe/jepitan power supply menempel stabil (goyang sedikit lalu amati apakah arus ikut berubah drastis)',
            'Jika ada indikasi bekas cairan, board perlu dibersihkan ultrasonic sebelum diagnosa lanjut',
          ];
        } else if (statusChangeCount > 5 && peakCurrent > NORMAL_MAX_MA_CLIENT * 0.5) {
          diagnosisIcon = Icons.repeat;
          diagnosisColor = Colors.blueAccent;
          diagnosisText = 'Pola Naik-Turun Berulang (Indikasi Bootloop)';
          diagnosisDetail = 'Status berubah-ubah $statusChangeCount kali — arus naik lalu turun berulang '
              'dengan puncak ${peakCurrent.toStringAsFixed(0)} mA. Khas board yang mencoba booting tapi gagal terus.';
          diagnosisSteps = [
            'Kemungkinan software corrupt — pertimbangkan flashing/reflash firmware',
            'Jika setelah flashing tetap sama, curigai IC PMIC tidak stabil atau RAM/CPU bermasalah (butuh reball)',
            'Cek juga apakah tombol power tertahan/short (bisa memicu restart loop palsu)',
          ];
        } else if (c > 5 && c < NORMAL_MAX_MA_CLIENT) {
          diagnosisIcon = Icons.check_circle;
          diagnosisColor = Colors.green;
          diagnosisText = 'Pola Arus Terlihat Normal';
          diagnosisDetail = 'Arus stabil di ${c.toStringAsFixed(0)} mA, tidak ada lonjakan, short, atau osilasi liar.';
          diagnosisSteps = [
            'Jalur power kemungkinan sehat',
            'Jika HP tetap tidak menyala/blank, cek tombol power, konektor LCD, atau coba flashing software',
            'Jika hidup tapi tidak connect sinyal, arahkan pemeriksaan ke area RF/baseband terpisah',
          ];
        } else if (c <= 5) {
          diagnosisIcon = Icons.hourglass_empty;
          diagnosisColor = Colors.grey;
          diagnosisText = 'Standby / Belum Ada Aktivitas Berarti';
          diagnosisDetail = 'Arus masih sangat kecil (${c.toStringAsFixed(1)} mA). Board mungkin baru di tahap '
              'standby PMIC atau probe baru saja disentuhkan.';
          diagnosisSteps = ['Tunggu beberapa detik lagi untuk melihat apakah arus mulai naik (proses boot)'];
        } else {
          diagnosisIcon = Icons.hourglass_empty;
          diagnosisColor = Colors.grey;
          diagnosisText = 'Mengamati Pola...';
          diagnosisDetail = 'Sistem sedang mengumpulkan data untuk analisa.';
          diagnosisSteps = [];
        }
    }
  }

  int _computeOscillationScore(List<double> samples) {
    if (samples.length < 4) return 0;
    int reversals = 0;
    for (int i = 2; i < samples.length; i++) {
      final d1 = samples[i - 1] - samples[i - 2];
      final d2 = samples[i] - samples[i - 1];
      if (d1.sign != d2.sign && (d1.abs() > 20 || d2.abs() > 20)) {
        reversals++;
      }
    }
    return reversals.clamp(0, 10);
  }

  // ---- Fungsi bantu untuk fitur isolasi komponen ----
  void _startIsolation() {
    isolationBaseline = current;
    isolationLog.clear();
  }

  void _recordIsolation(String label) {
    final baseline = isolationBaseline ?? current;
    final delta = baseline - current;
    isolationLog.add({
      'label': label,
      'before': baseline,
      'after': current,
      'delta': delta,
    });
    isolationBaseline = current;
    setState(() {});
  }

  void _onData(List<int> value) {
    final str = utf8.decode(value, allowMalformed: true);
    final parts = str.split(',');
    if (parts.length != 3) return;

    final v = double.tryParse(parts[0]) ?? 0;
    final c = double.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2]) ?? 0;

    setState(() {
      voltage = v;
      current = c;
      status = s;
      t += 1;
      currentHistory.add(FlSpot(t, c));
      if (currentHistory.length > 60) currentHistory.removeAt(0);
      _analyze(s, v, c);
    });

    if (s == 1) {
      // alarm tambahan bisa ditambahkan di sini
    }
  }

  void _sendCommand(String cmd) async {
    if (commandChar != null) {
      await commandChar!.write(utf8.encode(cmd));
    }
  }

  @override
  void dispose() {
    sub?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monitoring Real-Time')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: statusColor[status]!.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: statusColor[status]!, width: 2),
              ),
              child: Row(
                children: [
                  Icon(
                    status == 1 ? Icons.warning_amber : Icons.info_outline,
                    color: statusColor[status],
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    statusText[status] ?? 'UNKNOWN',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: statusColor[status],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(child: _statCard('Tegangan', '${voltage.toStringAsFixed(3)} V')),
                const SizedBox(width: 12),
                Expanded(child: _statCard('Arus', '${current.toStringAsFixed(1)} mA')),
              ],
            ),
            const SizedBox(height: 16),

            const Text('Grafik Arus (mA) vs Waktu', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  minY: 0,
                  gridData: const FlGridData(show: true),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: currentHistory,
                      isCurved: true,
                      color: Colors.deepPurpleAccent,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: diagnosisColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: diagnosisColor.withOpacity(0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(diagnosisIcon, color: diagnosisColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          diagnosisText,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: diagnosisColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    diagnosisDetail,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                  if (diagnosisSteps.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Saran langkah:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    ...diagnosisSteps.map((s) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('•  ', style: TextStyle(fontSize: 13)),
                              Expanded(child: Text(s, style: const TextStyle(fontSize: 12.5, height: 1.3))),
                            ],
                          ),
                        )),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Catatan: ini analisa awal berbasis pola arus, bukan diagnosis pasti. '
                    'Tetap lakukan verifikasi fisik pada board.',
                    style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => _sendCommand('CUTOFF'),
                    icon: const Icon(Icons.power_off),
                    label: const Text('Cut-off Manual'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    onPressed: () => _sendCommand('RESET'),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Reset / Nyalakan'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            Row(
              children: [
                const Text('Tegangan Set (V):'),
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: voltageSetController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            const Divider(),
            const SizedBox(height: 8),
            const Text('Isolasi Komponen', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Text(
              'Lepas konektor satu-satu (LCD, kamera, dst), lalu tekan tombol di bawah setelah tiap pelepasan. '
              'Komponen dengan penurunan arus (delta) terbesar adalah kandidat utama penyebab short.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _startIsolation,
              icon: const Icon(Icons.flag),
              label: Text(isolationBaseline == null
                  ? 'Mulai Sesi Isolasi (catat baseline)'
                  : 'Ulangi Baseline (${isolationBaseline!.toStringAsFixed(0)} mA)'),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: commonSuspects.map((label) {
                return ActionChip(
                  avatar: const Icon(Icons.link_off, size: 16),
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  onPressed: isolationBaseline == null ? null : () => _recordIsolation(label),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            if (isolationLog.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Riwayat Isolasi:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    ...isolationLog.reversed.map((log) {
                      final delta = log['delta'] as double;
                      final isCulprit = delta > 30;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(
                              isCulprit ? Icons.priority_high : Icons.remove,
                              size: 16,
                              color: isCulprit ? Colors.red : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${log['label']}: ${log['before'].toStringAsFixed(0)} → '
                                '${log['after'].toStringAsFixed(0)} mA '
                                '(Δ${delta.toStringAsFixed(0)} mA)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isCulprit ? FontWeight.bold : FontWeight.normal,
                                  color: isCulprit ? Colors.redAccent : Colors.white70,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 6),
                    const Text(
                      'Δ (delta) besar = arus turun banyak setelah komponen itu dilepas → kandidat penyebab short.',
                      style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
