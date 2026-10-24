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
5. **Zoom chart sampai paling besar** (tekan `+` beberapa kali). MT5 membatasi jarak antar candle maksimal 32 piksel, jadi angka hanya muncul di zoom terbesar. Di zoom kecil sel tetap tampil sebagai heatmap warna.
6. Tarik skala harga ke atas/bawah supaya tiap baris cukup tinggi untuk angka.

## Pengaturan utama
| Pengaturan | Default | Keterangan |
|---|---|---|
| Bars to calculate | 150 | Jumlah candle yang dihitung (makin banyak, makin berat) |
| Row size in points | 0 (auto) | Ukuran tiap level harga. Auto ≈ 20 baris per candle |
| Display mode | Split | Split / Delta / Volume / Profile |
| Value Area % | 70 | |
| Imbalance ratio | 3.0 | |
| Stacked imbalance | 3 | |
| Theme | Institutional Dark | Dark / Light / Custom |

**Saran untuk XAUUSD / NAS100:** timeframe M5–M15, Row size auto atau diatur manual (misalnya XAUUSD 50 poin = $0.50).

## Catatan
- Butuh riwayat tick dari broker. Saat pertama dipasang, MT5 bisa butuh beberapa detik untuk mengunduhnya, dan candle akan muncul bertahap.
- Saat indikator dilepas, warna chart dan candle dikembalikan seperti semula.
