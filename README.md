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

# Liquidity Heatmap (EA) untuk MT5

Heatmap likuiditas order book, mirip Orderbook Heatmap di OpenMarket. Datanya diambil dari order book publik **Hyperliquid**:
- **XAUUSD** memakai `xyz:GOLD`
- **NAS100 / USTEC / US100** memakai `xyz:XYZ100`

Selisih harga ke broker dikoreksi otomatis.

**EA ini hanya menampilkan data. Tidak ada satu pun fungsi trading di dalamnya.** Bentuknya EA, bukan indikator, karena MT5 melarang indikator mengakses internet.

## Cara kerja
1. Setiap 2 detik, EA mengambil snapshot order book: 20 level bid dan 20 level ask, dikelompokkan per $1 untuk emas atau per $10 untuk Nasdaq.
2. Offset dihitung otomatis: harga tengah broker dikurangi harga tengah Hyperliquid. Semua level digeser sebesar offset itu.
3. Snapshot disusun dari waktu ke waktu dan diwarnai sesuai besarnya order: biru (kecil) → cyan → kuning → putih (sangat besar).
4. Di kanan ada **ladder** order book saat ini. Level yang besarnya ≥ 3× median ditandai sebagai **BID WALL / ASK WALL** dengan garis kuning.
5. Riwayat heatmap disimpan ke file, jadi tidak hilang saat MT5 ditutup.

## Instalasi
1. Salin `MQL5/Experts/LiquidityHeatmap.mq5` ke folder `MQL5/Experts/`, lalu compile (F7).
2. MT5: **Tools → Options → Expert Advisors** → centang **Allow WebRequest for listed URL** → tambahkan `https://api.hyperliquid.xyz`.
3. Buka chart **XAUUSD M1** (heatmap paling jelas di M1–M5), lalu seret **LiquidityHeatmap** ke chart.
4. Heatmap terisi seiring waktu, karena tiap 2 detik bertambah satu kolom snapshot.

**Tips:** pakai di chart terpisah dari FootprintPro, atau set FootprintPro *Column width = 0*. Wide Mode FootprintPro memakai posisi kolom sendiri, jadi tidak sejajar dengan sumbu waktu heatmap.

## Catatan
- Likuiditas Hyperliquid berasal dari trader kripto, bukan CME. Tembok besarnya bermakna sebagai zona, tapi ukurannya lebih kecil daripada pasar emas utama.
- Gunakan sebagai **zona analisa**, bukan pemicu entry otomatis karena perbedaan kecepatan harga. Itu bisa dianggap latency arbitrage oleh prop firm.
