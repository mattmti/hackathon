## Benchmark Go — 2026-04-10 09:41

### Environnement

| Paramètre | Valeur |
|-----------|--------|
| OS | MINGW64_NT-10.0-26200 |
| Docker | 29.0.1 |
| Image consumer | hackathon-barcode-generator-consumer |

### Résultats

| Métrique | Valeur |
|----------|--------|
| Messages testés | 2000 |
| Temps total | 11s |
| Débit moyen | 181 msg/s |
| Latence moyenne | 5 ms/msg |
| Débit P50 | 44 msg/s |
| Débit P95 | 1810 msg/s |
| Débit P99 | 1810 msg/s |
| CPU pic | 380.55% |
| RAM pic | 15.77MiB |


---

## Benchmark PHP — 2026-04-10 09:44

### Environnement

| Paramètre | Valeur |
|-----------|--------|
| OS | MINGW64_NT-10.0-26200 |
| Docker | 29.0.1 |
| PHP | 8.2 |
| Librairie barcode | picqer/php-barcode-generator |

### Résultats

| Métrique | Valeur |
|----------|--------|
| Messages testés | 2000 |
| Temps total | 26s |
| Débit moyen | 76 msg/s |
| Latence moyenne | 13 ms/msg |
| Débit P50 | 190 msg/s |
| Débit P95 | 491 msg/s |
| Débit P99 | 491 msg/s |
| CPU pic | 37.45% |
| RAM pic | 15.46MiB |



