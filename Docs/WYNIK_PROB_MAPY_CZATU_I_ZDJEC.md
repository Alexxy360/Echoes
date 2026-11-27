# Wynik prób mapy, czatu i adresów zdjęć

Po odpowiedzi właściciela **„Tak, zatwierdzam obie próby”** wykonano oba zakresy z commitu `02f099f`, wyłącznie w publicznym CloudKit Development `iCloud.mpvEcho.Echo` / zespół `22YC9RAP4P`. **Ograniczony test zapytań zaliczony i posprzątany. Próba adresów uploadu niezaliczona.** [Dowody](evidence/community-query-and-grants-development-results.json).

| Próba | Rzeczywisty wynik |
| --- | --- |
| Mapa/obecność | Trzy oczekiwane wyniki na dwóch stronach; zachowana kolejność, także przy równych datach |
| Wiadomości | Trzy oczekiwane wyniki na dwóch stronach; zachowana kolejność i komplet wyników |
| Zapytania | Apple przyjął NEAR/filter/sort/continuation z dodatkowym IN do dokładnie sześciu własnych ID typu. Z query pobierano ownerKey i metadata |
| Sprzątanie | Świeży lookup i aktualne change tags poprzedziły warunkowe delete. Końcowy lookup potwierdził brak wszystkich12rekordów; trwały journal revision21/state settled,12statusów absent,0pending/kolizji/IO |
| Adresy zdjęć | Dokładnie jedna próba assets/upload zakończona GRANT_RESPONSE. Brak zaakceptowanego raportu hostów;0uploadów,0zapisów rekordów,0otwartych URL. Nie ponawiano requestu |

R-02 wykorzystał10/32wywołań w jednym oknie do30min: preflight12ID, jeden create12, dokładny odczyt, po2strony każdego typu, świeży odczyt do cleanup, warunkowe delete i potwierdzenie nieobecności. Inwentarz SHA `54a7a6eba5d08808695897c7a8aea6464d78bc2a02b6658ebd0ba83777317b05`. Współrzędne0/0 lub1/1 były syntetyczne; próba nie korzystała z telefonu lub GPS.

R-03a użył oddzielnego okna do30min i inwentarza SHA `68595368b901c87add1cf25631a55d991b8651dcaf072698d4803f5bae3dcb7f`. Stary CLI zachował jedynie ogólny kod błędu, bez statusu HTTP lub surowej odpowiedzi. **Przyczyny rzeczywistego błędu nie znamy.** Mogły powstać czasowe granty po stronie Apple; narzędzie nie ma operacji tworzenia rekordu lub wysłania obrazu. Nie usuwano definicji ani danych innych osób.

Podpisy tworzono lokalnie istniejącym kluczem Community Development; nie tworzono kluczy lub ról i nie przekazywano prywatnego PEM do Cloudflare. Po zakończeniu usunięto oba pliki permit, zachowując inwentarze, attempt i dowody. Nie rozszerzano okien, schematu, uprawnień ani zakresu odczytu.

## Potwierdzony lokalnie błąd i poprawka

Przegląd wykazał takie samo porównywanie Content-Length z odkodowanym body w narzędziu grantów oraz produkcyjnym CloudKitAvatarAssets. Prawdziwy fetch do lokalnego serwera gzip odtworzył oba błędy przed poprawką (2/2testy niezaliczone). Fetch może zachowywać długość skompresowanej reprezentacji po rozpakowaniu odpowiedzi; opisuje to również [repozytorium Undici](https://github.com/nodejs/undici/issues/2514).

Oba odczyty porównują teraz długość tylko dla identity. Niezależnie od kodowania nadal ograniczają faktycznie odkodowany strumień do16KiB oraz zachowują limity fragmentów/czasu. Niedozwolone kodowanie, niezgodna długość identity, obce rekordy/pola i niebezpieczne URL nadal są odrzucane. Nie dodano hostów lub wildcardu do konfiguracji.

CLI dostał zamkniętą diagnostykę: etap, status HTTP, boolean typu JSON, kodowanie z enum, liczby bajtów/tokenów, znany kod serwera i stałą kategorię odmowy. Nie zapisuje body, dowolnego reason, nagłówków, ścieżek, URL, tokenów ani kluczy. Nowe testy sprawdzają rzeczywiste lokalne gzip, limit po rozpakowaniu, odmowę błędnej długości/kodowania i brak sekretów w diagnostyce. **Ten lokalny dowód nie dowodzi, że pierwsza odpowiedź Apple była gzip.**

42/42wybranych testów po poprawce na Node24.22.3, pełne992/992bez skipów na Node22.23.5 oraz992/992na Node24.22.3,5kontroli składni Node22. Dodano5funkcji testowych. Oficjalny runtime Node22 odtworzono lokalnie i sprawdzono SHA archiwum; stary shim Firebase nie był działającym runtime i nie został użyty do testów. Pakiet rzeczywistego Workera zbudowany w wyłączonej konfiguracji, **bez wdrożenia**. Kod iOS, zależności, projekt Xcode i stare dane Firebase zachowane; nie ponawiano kompilacji iOS bez zmiany źródeł.

## Następny krok i granice

Przygotowano [jedną ponowną próbę grantów](ZAKRES_PONOWNEJ_PROBY_GRANTOW_DEVELOPMENT.md) z nowym inwentarzem i poprawionym CLI, bez jej wykonania. Nowy request wymaga konkretnej zgody; pierwsza jednorazowa próba jest zużyta.

Ograniczenie query do własnych ID nie dowodzi całej produkcyjnej ścieżki bez IN, pojemności większych stron/kanału, wszystkich granic3km/czasu ani zwykłych A/B. Konto operatora ma rolę administratora. R-03 nie ma jeszcze rzeczywistych zaakceptowanych hostów, obrazów, uploadu/CAS/chronionego CDN i sprzątania plików. Rzeczywiste OAuth refresh/revoke, retencja/erasure/PITR, pełny zwykły AppServices i TestFlight nadal wymagają odbioru. [Mapa](ODBIOR_MIGRACJI_STAN_I_KOLEJNOSC.md). Nie uruchomiono opłat lub zmian Production; Cloudflare w tych próbach nie był używany ani zmieniany.
