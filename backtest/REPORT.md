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
