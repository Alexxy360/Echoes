# Jedna ponowna próba adresów uploadu — CloudKit Development

**Wykonane po odpowiedzi „Tak, zatwierdzam jedną ponowną próbę”.** Jednorazowy limit zużyty: HTTP200/JSON/gzip/2tokeny, odmowa url_canonical. [Dokładny wynik](WYNIK_PONOWNEJ_PROBY_GRANTOW.md). Poprzednia jednorazowa próba została wykonana i nie przeszła; nie jest ponawiana automatycznie. [Wynik i poprawka](WYNIK_PROB_MAPY_CZATU_I_ZDJEC.md).

Nowy dokładny inwentarz SHA-256: `fac1e30092f49f99f2b951009775123e56177f767bb5c705420b40c95ff6f422`. Nie zmienia się mechanika próby: publiczne **Development**, `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`, schema SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`.

Po konkretnej zgodzie: jedno świeże okno do30min, nowy jednorazowy permit i maksymalnie1request `assets/upload` do `api.apple-cloudkit.com`, tylko pola `image` i `thumbnail` jednego nowego losowego EchoesAvatarV1. Istniejący lokalny klucz **Echoes Community Development 2026-11-19**, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, SPKI SHA `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`, zachowuje prawa administratora publicznego Development, także poza3km. Bez tworzenia klucza/roli albo przekazywania PEM Cloudflare.

Użyty zostanie poprawiony CLI: obsługa odkodowanego gzip przy zachowaniu16KiB/64fragmentów/8s i ścisłej walidacji grantów. Diagnostyka zapisuje wyłącznie zamknięte metadata etapu/statusu/kodowania/rozmiaru/stałego kodu błędu; bez surowych URL, tokenów, body, reason lub kluczy. Po sukcesie raport zawiera tylko pełne zweryfikowane hosty i przypisanie do pól. Po błędzie zachowujemy attempt, bez drugiego requestu lub zmiany okna.

Bez wysyłania obrazu, otwierania otrzymanych adresów, zapisu/usuwania rekordu, query, danych użytkowników, prywatnych baz/profili, GPS/Muzyki, telefonu, nowych praw, schematu, hostingu/sekretów w Cloudflare, Production, Firebase, TestFlight i opłat. Mogą powstać czasowe granty po stronie Apple także przy niepewnym wyniku, bez utworzenia rekordu/obrazu w tej próbie.

Inwentarz naprawdę przygotowano i odczytano lokalnie przez nieaktywny prepare/inspect, bez permitu/attempt/żądań. Kod, lokalna regresja i pakiet są opisane w [raporcie](WYNIK_PROB_MAPY_CZATU_I_ZDJEC.md). Sukces rozpoznania hostów nie jest odbiorem uploadu plików lub całej migracji.


## Po wykonaniu

Nie ponawiano requestu ani nie otwierano URL;0uploadów i0zapisów rekordów. Permit usunięty, attempt zachowany. Lokalnie poprawiono równoważne zapisy authority HTTPS; konkretna różnica wcześniejszego URL pozostaje nieznana. Nowy budżet opisuje [oddzielna seria do3prób](ZAKRES_SERII_GRANTOW_DEVELOPMENT.md), bez zgody, rezerwacji i sieci. Poprzednia zgoda nie obejmuje tej serii.
