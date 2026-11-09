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

---

# Eksplorasi aturan: double bottom & bear flag + counter position (v3), `explore_bt.py`

**Data**
- H1: 196 pair, 15 Apr – 9 Nov 2026. API Hyperliquid hanya menyimpan 5000 candle terakhir, jadi H1 hanya sekitar 7 bulan.
- 4H: Jul 2024 – Nov 2026.
- 1D: 2023 – Nov 2026.

**Metode:** mulai dari aturan dasar, lalu ubah **satu aturan per satu**. Kombinasi dipilih di 4H, lalu divalidasi di H1 dan 1D.

**Pembanding (entry acak, profit factor):**

| Timeframe | Long | Short |
|---|---|---|
| H1 | 0,88 | 0,94 |
| 4H | 0,66 | 1,29 |
| 1D | 0,70 | 0,89 |

## Temuan
- **Kombinasi terbaik di 4H tidak lolos validasi.**
  - Double bottom toleransi 0,25 + dasar kedua lebih tinggi: PF 1,91 di 4H, tapi 1,03 di H1.
  - Bear flag jeda ≤ 8 + retrace ≤ 38%: PF 4,86 di 4H, tapi 1,05 di H1 dan 0,85 di 1D.
  - Artinya aturan-aturan itu cocok dengan kebetulan di data 4H (overfit).
- **Lolos di ketiga timeframe (mengalahkan acak di semuanya):**

| Setup | H1 PF (n) | 4H PF (n) | 1D PF (n) |
|---|---|---|---|
| **Bear flag: pole ≥ 3 ATR + harga < SMA200** (short) | **1,89** (75) · OOS 2,15 | **1,51** (101) · OOS 1,84 | 1,66 (23) |
| Double bottom: dasar kedua lebih tinggi + volume ≥ 1,5× (long) | 1,24 (82) · OOS 0,68 | 1,33 (87) · OOS 2,09 | 1,59 (12) |

- **Counter position (balik arah setelah breakout gagal): tidak direkomendasikan.**

| Counter untuk | H1 PF | 4H PF | 1D PF |
|---|---|---|---|
| Double bottom gagal (SAR / CONFIRM) | 0,76 / 0,83 | 0,77 / 0,72 | 3,07 / 4,44 (n = 29 / 7) |
| Bear flag gagal (SAR / CONFIRM) | 1,23 / 1,72 (n = 25 / 14) | 0,25 / 0,00 | 0,41 / 0,87 |

  Hasilnya tidak konsisten antar timeframe. Satu-satunya angka bagus berasal dari sampel yang sangat kecil.
- **Exit:** tidak ada exit yang selalu menang.
  - Trailing tertinggal 3R (aturan kamu) terbaik untuk bear flag di 4H.
  - TP tetap 3R lebih stabil di 1D.
  - T2 (breakeven di 2R) tidak lebih baik.

---

# Bear flag di timeframe rendah dengan data Binance (v4), `bf_lowtf.py`

**Kenapa Binance?** API Hyperliquid hanya menyimpan 5000 candle terakhir: 1h ≈ 7 bulan, 15m ≈ 52 hari. Arsip publik Binance Futures (data.binance.vision) punya candle **1h dan 15m dari Jan 2023 – Okt 2026** untuk 214 dari 235 koin Hyperliquid.
- Aturan, entry, stop, trailing dan **biaya Hyperliquid** dibuat sama persis.
- Detektor vectorized sudah diverifikasi menghasilkan sinyal **identik** dengan detektor lama di 196 koin HL 1h.
- Filter likuiditas: rata-rata volume harian Binance ≥ $50 juta. Dites juga $20 juta dan $100 juta.

## Hasil (setup ROBUST: pole ≥ 3 ATR + di bawah SMA200)

| Data | Trade | Win rate | Rata-rata | PF | PF periode akhir | Per tahun (R) | Acak short PF |
|---|---|---|---|---|---|---|---|
| **Binance 1h**, 2023–2026 | **865** | 29,4% | +0,16R | **1,21** | 0,88 | 2023 −63 · 2024 +188 · 2025 −15 · 2026 +24 | 1,01 |
| Binance 1h, TP 3R | 888 | 32,9% | +0,22R | 1,30 | 0,91 | 2023 −60 · 2024 +218 · 2025 +6 · 2026 +29 | 1,01 |
| **Binance 15m**, 2023–2026 | 2275 | 23,3% | −0,07R | **0,92** | 0,77 | rugi di 3 dari 4 tahun | 0,90 |
| Hyperliquid 1h, Mei–Nov 2026 | 75 | 38,7% | +0,57R | 1,89 | 2,46 | — | 0,72 |
| Binance 1h, **periode yang sama** (Mei–Nov 2026) | 71 | 33,8% | +0,29R | 1,36 | — | — | — |

**Sensitivitas likuiditas (Binance 1h, ROBUST):** PF 1,22 (≥ $20 juta, 1315 trade) · 1,21 (≥ $50 juta) · 1,19 (≥ $100 juta). Entry acak selalu sekitar 1,00.

## Kesimpulan
- Hasil Hyperliquid 1h selama 7 bulan (PF 1,89) **terlalu optimis**. Di periode yang sama, data Binance memberi 1,36. Dalam 3,75 tahun, PF-nya 1,21.
- **1h masih punya edge kecil di atas acak** (+0,16R per trade vs +0,01R), tapi tidak stabil: hampir semua profit datang dari 2024. Tahun 2023 dan 2025 negatif, dan PF di periode akhir < 1.
- **15m tidak punya edge.** Hasilnya sama dengan entry acak, sama-sama rugi setelah biaya.
