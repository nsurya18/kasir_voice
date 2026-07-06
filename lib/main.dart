import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  Hive.init(dir.path);
  await Hive.openBox('transaksi');
  runApp(const KasirSuaraApp());
}

class KasirSuaraApp extends StatelessWidget {
  const KasirSuaraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kasir Suara UMKM',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const KasirPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class KasirPage extends StatefulWidget {
  const KasirPage({super.key});

  @override
  State<KasirPage> createState() => _KasirPageState();
}

class _KasirPageState extends State<KasirPage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;

  String namaPembeli = "Menunggu suara...";
  String teksSuara = "Tekan 'Mulai Bicara' lalu sebutkan belanjaan.";
  int total = 0;
  List<Map<String, dynamic>> transaksi = [];

  late Box box;

  // 🔑 KUNCI API KEY SEGAR ANDA SUDAH TERPASANG AMAN
  final String _geminiApiKey = "AIzaSyBACzqLKsFzULjuZeV2Yohr_9TS0LV1KkQ";

  @override
  void initState() {
    super.initState();
    box = Hive.box('transaksi');
    _muatDataDariHive();

    // Inisialisasi mikrofon tunda agar HP tidak lag/freeze saat start-up
    Future.delayed(Duration.zero, () async {
      try {
        await _speech.initialize(
          onStatus: (val) => print('Status Mic: $val'),
          onError: (val) => print('Error Mic: $val'),
        );
      } catch (e) {
        print("Gagal inisialisasi mic: $e");
      }
    });
  }

  void _muatDataDariHive() {
    if (box.isNotEmpty) {
      int hitungTotal = 0;
      List<Map<String, dynamic>> listLokal = [];
      for (var i = 0; i < box.length; i++) {
        final item = box.getAt(i);
        if (item != null) {
          final Map<String, dynamic> dataKonversi = Map<String, dynamic>.from(
            item,
          );
          listLokal.add(dataKonversi);
          hitungTotal += (dataKonversi['harga'] as int? ?? 0);
        }
      }
      setState(() {
        transaksi = listLokal;
        total = hitungTotal;
      });
    }
  }

  void _listen() async {
    if (!_isListening) {
      bool available = await _speech.initialize(
        onStatus: (val) => print('Status: $val'),
        onError: (val) => print('Error: $val'),
      );
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          localeId:
              "id_ID", // Mengunci mikrofon ke Bahasa Indonesia murni di HP Android
          onResult: (val) => setState(() {
            teksSuara = val.recognizedWords;
            if (val.finalResult) {
              _isListening = false;
              _prosesTeksDenganAI(teksSuara);
            }
          }),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  void _prosesTeksDenganAI(String teksMentah) async {
    if (teksMentah.isEmpty) return;

    setState(() {
      namaPembeli = "Sedang menghitung...";
    });

    // Jalur resmi Gemini-1.5-Flash bebas dari gangguan backslash (\)
    final Uri url = Uri.parse("https://googleapis.com$_geminiApiKey");

    String prompt =
        "Kamu adalah sistem kasir pintar warung Indonesia. Tugasmu mengubah teks transaksi acak menjadi JSON murni yang rapi. Identifikasi nama pembeli, nama barang, dan harga angka murninya. Konversi nominal slang Indonesia (seperti ceban = 10000, goceng = 5000, dua puluh ribu = 20000) menjadi integer angka murni tanpa titik. Teks transaksi mentah: $teksMentah ATURAN MUTLAK: Kamu HANYA boleh mengeluarkan output berupa string JSON murni tanpa pembuka basa-basi dan tanpa tag markdown. Jika teks tidak jelas, isi properti dengan default. Format Output Wajib JSON: {\"pelanggan\": \"Nama\", \"barang\": \"Nama Barang\", \"harga\": 15000}";

    try {
      final respon = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-client': 'genai-js',
        },
        body: jsonEncode({
          "contents": [
            {
              "parts": [
                {"text": prompt},
              ],
            },
          ],
          "generationConfig": {
            "temperature": 0.1,
            "responseMimeType": "application/json",
          },
        }),
      );

      if (respon.statusCode == 200) {
        final dataRespon = jsonDecode(respon.body);
        String teksJsonMurni =
            dataRespon['candidates'][0]['content']['parts'][0]['text'];

        teksJsonMurni = teksJsonMurni
            .replaceAll("```json", "")
            .replaceAll("```", "")
            .trim();
        final Map<String, dynamic> hasilAkhir = jsonDecode(teksJsonMurni);

        String pelangganFix = hasilAkhir['pelanggan'] ?? "Umum";
        String barangFix = hasilAkhir['barang'] ?? "Belanjaan";
        int hargaFix = hasilAkhir['harga'] ?? 0;

        // Menyimpan data hasil analisa AI secara permanen ke database lokal Hive Box
        final Map<String, dynamic> dataSimpan = {
          "pelanggan": pelangganFix,
          "barang": barangFix,
          "harga": hargaFix,
        };

        await box.add(dataSimpan);

        setState(() {
          namaPembeli = pelangganFix;
          transaksi.add(dataSimpan);
          total += hargaFix;
        });
      } else {
        setState(() => namaPembeli = "Google API Error (${respon.statusCode})");
      }
    } catch (e) {
      print("Eror sistem parsing: $e");
      setState(() => namaPembeli = "Gagal Membaca Data");
    }
  }

  Future<void> _kirimWhatsApp() async {
    if (transaksi.isEmpty) return;

    String pesan =
        "*🧾 LAPORAN OMZET HARIAN KASIR*\n"
        "----------------------------------------\n"
        "Tanggal  : 06 Juli 2026\n\n"
        "*Rincian Transaksi Terbuku:*\n";

    for (var t in transaksi) {
      pesan += "• ${t['pelanggan']} beli ${t['barang']} - Rp ${t['harga']}\n";
    }

    pesan +=
        "----------------------------------------\n"
        "*TOTAL OMZET: Rp $total*\n\n"
        "Data tersimpan otomatis di Hive Database. 🙏";

    final nomor = "6282121663301";
    final uri = Uri.parse(
      "https://wa.me/$nomor?text=${Uri.encodeComponent(pesan)}",
    );

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Kasir Suara + Hive DB",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blue.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep, color: Colors.white),
            tooltip: "Reset Database",
            onPressed: () async {
              await box.clear();
              setState(() {
                transaksi.clear();
                total = 0;
                namaPembeli = "Menunggu suara...";
                teksSuara = "Tekan 'Mulai Bicara' lalu sebutkan belanjaan.";
              });
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "Status: $namaPembeli\nTranskrip: $teksSuara",
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.blue.shade900,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: transaksi.isEmpty
                  ? const Center(
                      child: Text(
                        "Belum ada transaksi hari ini.",
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: transaksi.length,
                      itemBuilder: (context, index) {
                        final t = transaksi[index];
                        return Card(
                          elevation: 0.5,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            leading: CircleAvatar(child: Text("${index + 1}")),
                            title: Text(
                              "${t['pelanggan']} beli ${t['barang']}",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: const Text("Tersimpan di Hive Box"),
                            trailing: Text(
                              "Rp ${t['harga']}",
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(thickness: 2),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "OMZET HARI INI:",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade900,
                    ),
                  ),
                  Text(
                    "Rp $total",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: "Input manual teks transaksi warung",
                hintText: "Contoh: Budi membeli kopi sepuluh ribu",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.keyboard),
              ),
              onSubmitted: (value) {
                _prosesTeksDenganAI(value);
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _listen,
                    icon: Icon(_isListening ? Icons.stop : Icons.mic),
                    label: Text(_isListening ? "Stop Rekam" : "Mulai Bicara"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isListening
                          ? Colors.red.shade700
                          : Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _kirimWhatsApp,
                    icon: const Icon(Icons.share),
                    label: const Text("Kirim WA"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
