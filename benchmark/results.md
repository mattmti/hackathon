# Benchmark — PHP vs Go Consumer

## Environnement de test

| Paramètre | Valeur |
|-----------|--------|
| Machine | _à compléter_ |
| CPU | _à compléter_ |
| RAM | _à compléter_ |
| Docker version | _à compléter_ |
| OS | _à compléter_ |

---

## Méthodologie

1. Purge de la queue `barcodes`
2. Publication de N messages via l'API RabbitMQ Management
3. Attente que la queue soit vide (tous les messages consommés)
4. Mesure du temps total, débit et ressources

Les résultats sont ajoutés automatiquement par le script `benchmark/run-benchmark.sh`.
---

## Benchmark Go — 2026-04-08 16:30

| Métrique | Valeur |
|----------|--------|
| Messages testés | 100 |
| Temps total | 0.22s |
| Débit | 450.45 msg/s |
| Latence moyenne | 2.22 ms/msg |
| CPU avant | 0.00% |
| CPU après | 0.06% |
| RAM avant | 10.26MiB / 6.682GiB |
| RAM après | 10.16MiB / 6.682GiB |


---

## Benchmark Go — 2026-04-08 16:33

| Métrique | Valeur |
|----------|--------|
| Messages testés | 2000 |
| Temps total | 0.24s |
| Débit | 8403.36 msg/s |
| Latence moyenne | 0.12 ms/msg |
| CPU avant | 0.00% |
| CPU après | 0.00% |
| RAM avant | 10.32MiB / 6.682GiB |
| RAM après | 13.84MiB / 6.682GiB |


---

## Benchmark Go — 2026-04-08 16:35

| Métrique | Valeur |
|----------|--------|
| Messages testés | 300 |
| Temps total | 11s |
| Débit | 27 msg/s |
| Latence moyenne | 36 ms/msg |
| CPU avant | 0.00% |
| CPU après | 0.00% |
| RAM avant | 0B / 0B |
| RAM après | 4.789MiB / 6.682GiB |

