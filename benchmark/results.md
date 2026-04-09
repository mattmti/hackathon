
## Benchmark PHP — 2026-04-09 16:00

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
| Messages testés | 1000 |
| Temps total | 17s |
| Débit moyen | 58 msg/s |
| Latence moyenne | 17 ms/msg |
| Débit P50 | 151 msg/s |
| Débit P95 | 477 msg/s |
| Débit P99 | 477 msg/s |
| CPU pic | 39.54% |
| RAM pic | 11.95MiB |


---



---

## Benchmark Go — 2026-04-09 16:08

### Environnement

| Paramètre | Valeur |
|-----------|--------|
| OS | MINGW64_NT-10.0-26200 |
| Docker | 29.0.1 |
| Image consumer | hackathon-barcode-generator-consumer |

### Résultats

| Métrique | Valeur |
|----------|--------|
| Messages testés | 1000 |
| Temps total | 20s |
| Débit moyen | 50 msg/s |
| Latence moyenne | 20 ms/msg |
| Débit P50 | 21 msg/s |
| Débit P95 | 338 msg/s |
| Débit P99 | 338 msg/s |
| CPU pic | 62.79% |
| RAM pic | 8.625MiB |

