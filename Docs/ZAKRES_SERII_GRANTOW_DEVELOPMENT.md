# Seria rozpoznania grantów — do3 żądań CloudKit Development

**Przygotowana, niezatwierdzona i niewykonana.** Poprzedni zatwierdzony request fac1e300… zakończył się HTTP200/2granty/url_canonical. [Wynik i sprawdzona lokalnie poprawka](WYNIK_PONOWNEJ_PROBY_GRANTOW.md). Ten zakres jest nowym budżetem, nie przedłużeniem poprzedniego okna.

Kontrakt SHA-256: `c222707fae22a2e0385c2bb0491170c97abc4a50166f70a88d0b2f01c4a25cca`. Dokładne inwentarze:

| Próba | SHA-256 |
| --- | --- |
| 1 | `978ddde5e42d1cda616f80692f550e47d31a61372655df21f66a19f45788eb4f` |
| 2 | `231b827b7d83f3d534efe96e93bbea063cac69df337e774882a5769e0cdcb9c4` |
| 3 | `1a2c9f8a809cd8d2e72172ad8767493c141411f1e2d898759dda9d76432183d5` |

Wyłącznie publiczne **CloudKit Development**, `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`, schema SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`. Istniejący lokalny klucz **Echoes Community Development 2026-11-19**, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, SPKI SHA `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`; dotychczasowe prawa administratora publicznego Development także poza3km. Nie tworzymy klucza/roli i nie przekazujemy PEM Cloudflare.

Po konkretnej zgodzie operator uruchomi najwyżej3oddzielne requesty `assets/upload` do `api.apple-cloudkit.com` w **jednym wspólnym oknie do30 min**,1 request dla każdego inwentarza. Każdy dotyczy pól `image`/`thumbnail` jednego własnego losowego EchoesAvatarV1. **Kończymy po pierwszym poprawnym rozpoznaniu hostów**; niewykorzystane próby nie są wysyłane. Nie uruchamiamy równoległych requestów i nie resetujemy attempt lub wspólnego terminu.

W razie odmowy można w ramach tego samego budżetu lokalnie poprawić i przetestować parser odpowiedzi/diagnostykę, wyłącznie bez zmiany zakresu sieci: metoda/odbiorca/kontener/typ/pola i lista trzech inwentarzy pozostają takie same. Nie jest to zgoda na szerszy odczyt, zmianę schematu, nowe prawa lub połączenie do zwróconych hostów. Dalszy request wymaga zakończonego poprzedniego procesu i nadal ważnego wspólnego okna; niepewność zachowujemy w dowodach, zużytego inwentarza nie powtarzamy. Po upływie30 min lub zużyciu3rezerwacji zatrzymujemy serię.

Odpowiedzi nadal do16 KiB/64 fragmentów/8 s. Zapis wyłącznie zweryfikowanych pełnych hostów/przypisania i liczników normalizacji albo zamkniętych metadanych błędu. Bez rawURL, tokenów, body, reason i kluczy w raporcie. Prywatny operator lokalny `run-batch.py` sprawdza wspólne limity i jednorazowe rezerwacje, a istniejący CLI dodatkowo kontroluje każdy pojedynczy request. Lokalny prepare/inspect obu warstw nie wykonuje sieci.

**Bez zdjęcia, uploadu bajtów, otwierania zwróconych adresów, zapisu/usuwania rekordu, query, danych użytkowników, prywatnych profili, GPS/Muzyki, telefonu, hostingu/sekretów w Cloudflare, nowych kluczy/ról/schematu, Production, Firebase, TestFlight i opłat.** Mogą powstać wyłącznie czasowe granty Apple także po niepewnym request; bez obrazu lub rekordu w tym kroku.

Pełny kontrakt i dowody przygotowania opisuje [raport](WYNIK_PONOWNEJ_PROBY_GRANTOW.md). Sukces tej serii nadal nie jest odbiorem przesłania obrazu, chronionego CDN, zwykłych A/B lub całego R-03.

Prywatne inwentarze, kontrakt i operator są zachowane lokalnie poza Git w trwałym katalogu operatora, z prawami0700/0600; nie kopiowano klucza. Okno serii nie jest rozpoczęte. Odtworzenie runtime przed startem nie zużywa rezerwacji.

Właściciel może ograniczyć zgodę do jednej próby. Operator wymaga zapisanego jawnego limitu1–3 i odmawia przekroczenia go, niezależnie od górnej granicy3 w kontrakcie. Bez nowej odpowiedzi zatwierdzony limit wynosi0.
