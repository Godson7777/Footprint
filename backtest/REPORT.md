# Backtest Breakout: Hyperliquid Perps (v1)

## Setup
- **Data:** semua perp Hyperliquid, termasuk yang sudah delisting (224 pair di 4H, 221 pair di 1D), langsung dari API Hyperliquid.
  - 4H: Juli 2024 – Nov 2026.
  - 1D: data sebelum Feb 2023 volumenya nol, jadi otomatis tersaring. Periode yang benar-benar teruji 2023–2026.
- **Filter likuiditas:** rata-rata volume harian 30 hari ≥ $5 juta, dihitung pada saat sinyal (tanpa look-ahead).
- **Entry:** di harga open candle berikutnya setelah candle sinyal ditutup.
- **Stop awal:** 2 × ATR(14). Jarak ini = 1R.
- **Exit (tanpa TP):**
  - Sampai harga mencapai +3R, stop tidak bergerak.
  - Di +3R, stop pindah ke entry + 0,1R.
  - Di +4R ke +1R, di +5R ke +2R, dan seterusnya (selalu tertinggal 3R dari puncak).
  - Gap melewati stop dieksekusi di harga open.
- **Biaya:** fee taker 0,045% per sisi, slippage 0,03% per sisi, tambahan 0,05% saat stop, dan funding 0,00125% per jam.
- **Aturan posisi:** satu posisi per pair. Pembanding: entry acak (RANDOM) dengan aturan exit yang sama.
- **Out-of-sample:** 40% trade terakhir menurut waktu entry.

## Pola
| Pola | Definisi |
|---|---|
| DONCHIAN | Close menembus high 20 candle sebelumnya (long) atau low 20 candle (short) |
| SQUEEZE | Bollinger width di persentil < 20% (dari 120 candle) dalam 5 candle terakhir, lalu breakout Donchian 20 |
| BASE | Range 30 candle ≤ 5 × ATR(100) (konsolidasi sempit), lalu close menembus high/low base |
| +VOL | Volume candle breakout ≥ 1,5 × rata-rata 20 candle |
| +TREND | Long hanya di atas SMA200, short hanya di bawah SMA200 |

## Hasil utama
**4H: tidak ada edge.**
- Semua varian profit factor 0,98–1,13.
- Kontrol acak: 0,96 secara keseluruhan, dan **1,30 untuk short**. Artinya profit dari short berasal dari tren turun altcoin selama periode ini, bukan dari polanya.
- Long breakout di 4H rugi di hampir semua varian.

**1D: ada kandidat. Long BASE + VOL + TREND:**

| Metrik | Nilai |
|---|---|
| Trade | 83 (Des 2023 – Okt 2026) |
| Win rate | 33,7% |
| Rata-rata | +0,56R per trade |
| Profit factor | 1,82 |
| Total | +46,3R |
| Max drawdown | 10,8R |
| Kontrol acak, long | PF 0,53 |
| Per tahun | 2024 +20,7R · 2025 −1,2R · 2026 +26,1R |
| Distribusi | 65% kena stop awal · 16% ≥ +3R menyumbang +86R |
| Ketergantungan outlier | Tanpa 3 trade terbaik, total hanya +9,4R |
| Posisi bersamaan | Maksimal 9 |

## Catatan kejujuran
- **Data-mining:** kandidat ini dipilih dari 13 varian × 2 arah. Sampelnya kecil (83 trade) dan sangat bergantung pada beberapa trade besar. Perlu divalidasi dengan data atau periode baru sebelum dipakai.
- **Aturan trailing 3R:** sekitar 27% trade sempat menyentuh 3R. Tapi semua pergerakan di bawah 3R tidak terlindungi sama sekali. Ini sumber utama win rate rendah.

---

# Chart Pattern Backtest (v2): `patterns_bt.py`

## Cara deteksi
- **Swing high/low (pivot):** 3 candle di kiri dan 3 di kanan. Pivot baru dianggap ada 3 candle setelah terbentuk, jadi tidak ada look-ahead.
- **Garis tren:** garis least-squares melalui 3 pivot terakhir dalam 100 candle. Kemiringan diukur dalam ATR per candle (|kemiringan| ≤ 0,03 dianggap datar). Setiap titik sentuh maksimal 0,6 ATR dari garisnya.
- **Breakout:** close pertama yang menembus garis atau neckline sejauh lebih dari 0,1 ATR, maksimal 30 candle setelah sentuhan terakhir.
- **Pola yang dites:**
  - Ascending, descending dan symmetrical triangle
  - Rectangle
  - Rising dan falling wedge
  - Bull dan bear flag (pole ≥ 4 ATR dalam 10 candle)
  - Double top dan double bottom (dua dasar berselisih ≤ 0,5 ATR)
  - Head & shoulders dan inverse (kepala ≥ 1 ATR melewati bahu)
- **Exit dan biaya:** sama dengan v1 (stop 2 ATR, trailing tertinggal 3R, tanpa TP).

## Hasil dibanding entry acak di arah yang sama
Baseline acak: **LONG** PF 0,66 (1D) / 0,76 (4H). **SHORT** PF 1,17 (1D) / 1,24 (4H).

| Pola | Arah | 1D PF (n) | 4H PF (n) | Kesimpulan |
|---|---|---|---|---|
| Double bottom | LONG | 1,30 (47) · +TREND 1,85 (32) | 1,35 (293) · OOS 1,47 | **Konsisten, jauh di atas acak** |
| Bear flag | SHORT | 2,21 (20) | 1,98 (60) · OOS 2,95 | **Konsisten**, sampel kecil |
| Rectangle | LONG | 0,37 (28) | 1,79 (137) · +TREND 2,03 (89) | Bagus di 4H saja |
| Rising wedge | SHORT | 1,64 (64) | 1,33 (433) · +TREND 1,81 (210) | Sedikit di atas acak |
| Falling wedge | LONG | 1,12 (115) | 0,86 (588) | Lemah |
| Ascending triangle | LONG | 0,48 (25) | 0,54 (170) | **Gagal** (di bawah acak) |
| Descending triangle | SHORT | 0,65 (31) | 1,19 (155) | Tidak ada edge |
| Symmetrical triangle | LONG/SHORT | 1,26 / 0,33 | 0,73 / 1,35 | Tidak konsisten |
| Head & shoulders | SHORT | 0,63 (38) | 1,00 (212) | Tidak ada edge |
| Double top | SHORT | 0,97 (42) | 1,00 (282) | Tidak ada edge |
| Inverse H&S | LONG | 1,31 (34) | 0,67 (226) | Tidak konsisten |
| Bull flag | LONG | n=6 | n=19 | Sampel terlalu kecil |

## Gabungan 4 pola terbaik (4H)
Double bottom LONG + bear flag SHORT + rectangle LONG (+TREND) + rising wedge SHORT (+TREND):

| Metrik | Nilai |
|---|---|
| Trade | 647 |
| Win rate | 29,7% |
| Rata-rata | +0,43R per trade |
| Profit factor | 1,61 |
| Total | +279,8R |
| Max drawdown | 50,9R |
| Losing streak terpanjang | 42 trade |
| Per tahun | 2024 (mulai Jul) +14,2R · 2025 +124,5R · 2026 +141,0R |
| Posisi bersamaan | Maksimal 26, wajib dibatasi |

**Catatan:** keempat pola ini dipilih setelah melihat hasilnya (seleksi post-hoc). Perlu forward test sebelum dipakai dengan uang sungguhan.
