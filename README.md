# Footprint Pro untuk MetaTrader 5

Indikator footprint (order flow) untuk MT5. Pengaturannya mengikuti Volume Footprint di OpenMarket.

## Fitur
- **Sel Bid × Ask per level harga**: mode split-bar, delta, total volume atau profile
- **POC**: level dengan volume terbesar, dikotak dan angkanya tebal
- **Value Area 70%**: garis VAH dan VAL
- **Imbalance diagonal**: rasio 3:1, angka diwarnai
- **Stacked imbalance zone**: minimal 3 level berturut-turut, zona diperpanjang sampai harga menembusnya
- **Naked POC**: opsional
- **Unfinished auction**: di high dan low candle
- **Panel statistik**: Delta, Max Delta, Min Delta dan Volume per candle
- **Hover inspector**: arahkan mouse ke sel untuk melihat detailnya
- **Tema Institutional Dark / Light**: atau warna custom
- **Badge sumber data**: `EXCHANGE DATA` atau `ESTIMATED FLOW`

## Penting: data di Forex/CFD (XAUUSD, NAS100, prop firm)
Broker CFD tidak mengirim volume transaksi asli atau sisi buy/sell. Di simbol seperti ini:
- Buy/Sell **diperkirakan dari arah tick**: harga naik dihitung buy, harga turun dihitung sell.
- Volume = **jumlah perubahan harga (tick volume)**.
- Header menampilkan badge oranye **ESTIMATED FLOW**.

Di simbol bursa (futures/saham dengan data trade asli), indikator otomatis memakai tanda BUY/SELL dan volume asli. Badge-nya hijau: **EXCHANGE DATA**.

## Instalasi
1. Di MT5: **File → Open Data Folder**.
2. Salin `MQL5/Indicators/FootprintPro.mq5` ke folder `MQL5/Indicators/`.
3. Buka **MetaEditor** (F4), buka file itu, lalu tekan **Compile** (F7).
4. Di MT5, buka Navigator → Indicators → seret **FootprintPro** ke chart.
5. Secara default indikator memakai **Wide Mode**. Kolom footprint selebar 90 piksel digambar sendiri oleh indikator, tidak mengikuti batas 32 piksel MT5. Skala harga otomatis menyesuaikan kolom yang terlihat, dan baris harga digabung otomatis sampai cukup tinggi untuk angka.
   - Geser chart (drag atau scroll) seperti biasa untuk melihat candle sebelumnya.
   - Sumbu waktu MT5 disembunyikan karena posisinya tidak cocok dengan kolom lebar. Waktu tiap candle tampil di baris **TIME** di panel bawah.
   - Mau kolom lebih lebar atau sempit? Ubah **Column width** (misalnya 120). Isi 0 untuk kembali mengikuti candle MT5.

## Pengaturan utama
| Pengaturan | Default | Keterangan |
|---|---|---|
| Column width | 130 px | Lebar kolom footprint (0 = ikuti candle MT5) |
| Auto-fit price scale | true | Skala harga menyesuaikan kolom yang terlihat |
| Min row height | 17 px | Baris digabung otomatis sampai setinggi ini |
| Max bars to calculate | 1000 | Batas candle yang dihitung. Candle di layar dimuat lebih dulu |
| Row size in points | 0 (auto) | Ukuran tiap level harga. Auto ≈ 20 baris per candle |
| Display mode | Split | Split / Delta / Volume / Profile |
| Focus mode | true | Imbalance dan POC menonjol, sel lain diredupkan |
| Value Area % | 70 | |
| Imbalance ratio | 3.0 | |
| Stacked imbalance | 3 | |
| Theme | Institutional Dark | Dark / Light / Custom |

**Saran untuk XAUUSD / NAS100:** timeframe M5–M15, Row size auto atau diatur manual (misalnya XAUUSD 50 poin = $0.50).

## Catatan
- Butuh riwayat tick dari broker. Saat pertama dipasang, MT5 bisa butuh beberapa detik untuk mengunduhnya, dan candle akan muncul bertahap.
- Saat indikator dilepas, warna chart dan candle dikembalikan seperti semula.

---

# Liquidity Heatmap + Iceberg (EA) untuk MT5

Heatmap likuiditas order book **historis**, gaya OpenMarket, ditambah **deteksi iceberg** gaya DeepCharts. Datanya dari OpenMarket (order book Hyperliquid):
- **XAUUSD** memakai `xyz:GOLD`
- **NAS100 / USTEC / US100** memakai `xyz:XYZ100`

**EA ini hanya menampilkan data. Tidak ada satu pun fungsi trading di dalamnya.**

## Fitur
- **Mengikuti sumbu waktu MT5.** Scroll ke belakang, dan heatmap periode itu otomatis diunduh lalu disimpan ke cache.
- **Gaya OpenMarket:** setiap candle menampilkan garis-garis kecil per level harga. Warnanya ungu (kecil) → biru → hijau → kuning → putih (sangat besar).
- **Walls:** level dengan ukuran di atas persentil 97% digambar kuning. Kalau bertahan beberapa candle, garisnya menyambung panjang.
- **Iceberg ala DeepCharts:** gelembung muncul di level di mana volume yang ditransaksikan ≥ 2× order yang terlihat, sementara harga tetap tertahan. Hijau untuk pembeli tersembunyi di bid, magenta untuk penjual tersembunyi di ask. Angka di dalamnya adalah perkiraan ukuran yang tersembunyi.
- **Strategy Tester:** membaca cache saja dan tidak pernah menampilkan data setelah waktu tester (tanpa look-ahead).
- **Offset harga otomatis per candle:** harga tipikal broker dikurangi VWAP Hyperliquid, dihaluskan dengan median 7 candle.

## Instalasi
1. Salin `MQL5/Experts/LiquidityHeatmap.mq5` ke `MQL5/Experts/`, lalu compile (F7).
2. Buat **agent token** OpenMarket di https://openmarket.xyz/chart/console/agents dengan akses **Read**. Simpan sendiri dan jangan dibagikan.
3. MT5: **Tools → Options → Expert Advisors** → centang **Allow WebRequest for listed URL** → tambahkan `https://mcp.openmarket.xyz`.
4. Seret **LiquidityHeatmap** ke chart XAUUSD (M1–H4), lalu tempel token di input **OpenMarket agent token**.
5. EA mengunduh riwayat bertahap, satu permintaan tiap 7 detik karena batas rate. Status tampil di panel kiri atas.

## Backtest
- **Replay manual / scroll:** cukup scroll ke belakang. Data dimuat otomatis, sejauh batas riwayat paket OpenMarket kamu (Free ±30 hari, Plus ±1 tahun).
- **Strategy Tester (visual mode):** jalankan EA di chart live dulu supaya cache terisi (*Bars to prefetch*, misalnya 2000). Setelah itu jalankan di Strategy Tester pada simbol dan timeframe yang sama. Cache dibaca dari folder Common.

## Catatan
- Likuiditas Hyperliquid berasal dari trader kripto, bukan CME. Wall dan iceberg berarti di pasar itu, dan levelnya dipetakan ke harga broker lewat offset.
- Iceberg di sini dihitung per candle dari data agregat (volume per harga dibanding ukuran book). Ini perkiraan kuantitatif, bukan deteksi tick-by-tick seperti DeepCharts.
- Pakai sebagai **zona analisa**, bukan pemicu entry otomatis karena perbedaan kecepatan harga (aturan latency arbitrage prop firm).
- Pakai di chart terpisah dari FootprintPro Wide Mode, atau set FootprintPro *Column width = 0*.
