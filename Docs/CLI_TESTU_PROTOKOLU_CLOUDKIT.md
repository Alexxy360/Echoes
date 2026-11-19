# Kontrolowane polecenia Development — CK-05a.4g

19 listopada 2026. CLI, prywatny permit, raport i odzyskiwanie są zaimplementowane i sprawdzone lokalnie. **Późniejsza, osobno zatwierdzona próba Apple CK-05a.4h przeszła: [odbiór metadanych i granice](ODBIOR_PROTOKOLU_COMMUNITY_DEVELOPMENT.md).** Poniżej opis implementacji i testów lokalnych CK-05a.4g. Model Individual został przyjęty osobno. [Zakres przygotowanej próby](ZAKRES_PROBY_COMMUNITY_DEVELOPMENT.md).

## Polecenia i granica aktywacji

`gateway/scripts/community-protocol-cli.mjs` ma cztery polecenia pozycyjne:

```
node scripts/community-protocol-cli.mjs prepare <prywatny-katalog-rodzic>
node scripts/community-protocol-cli.mjs inspect <katalog-próby> <SHA-inwentarza>
node scripts/community-protocol-cli.mjs run <katalog-próby> <SHA-inwentarza> <permit.json> <nowy-klucz.pem>
node scripts/community-protocol-cli.mjs cleanup <katalog-próby> <SHA-inwentarza> <nowy-permit.json> <nowy-klucz.pem>
```

Wymagane są bezwzględne ścieżki oraz obsługiwana wersja Node22/24 z `node:sqlite`. Przygotowanie i inspekcja nie potrzebują klucza ani zmiennych aktywacji, nie tworzą okna dostępu i nie wysyłają żądań. `prepare` tworzy nowy katalog0700, SQLite i kompletny `inventory.json`0600. `inspect` sprawdza dziennik/hash/inwentarz i pokazuje syntetyczny stan bez sieci.

`run`/`cleanup` odmawiają przed otwarciem plików, jeżeli `ECHOES_ALLOW_COMMUNITY_PROTOCOL_DEV` nie jest dokładnie `1`. Dalej wymagają zgodnego dziennika i prywatnego inwentarza, pełnego permit, bieżącego okna, odpowiedniego stanu full/cleanup i nowego klucza. Nie ma automatycznej aktywacji podczas importu modułu.

Permit ma dokładnie pola: schemaVersion=1, purpose=`echoes-community-protocol-development-v1`, scope identyczny z planem, planSHA256, window, keyID, publicKeySHA256, retiredKeyID, retiredPublicKeySHA256 oraz identityModel=`individual-owner-administrator-v1`. Window ma dokładnie id/issuedAt/expiresAt/mode; UUID, czas w milisekundach, maksymalnie30min, tryb full albo cleanup. Nie publikujemy wzoru wypełnionego permit i nie generujemy go przed konkretną zgodą.

**Permit jest zapisem operatora wiążącym osobno udzieloną zgodę z inwentarzem, kluczem i czasem. Nie dowodzi samodzielnie zgody użytkownika, odwołania starego klucza w Apple ani rzeczywistych uprawnień.** Te warunki wymagają odczytu konsoli i jawnego zapisu dowodów przed uruchomieniem. Plik zgody nie może zastępować tego odbioru.

## Klucz, pliki i cofnięcie zgody

Odczyty są ograniczone: permit/klucz8192B, inwentarz65536B, bez podążania za symlinkiem końcowego pliku, wyłącznie zwykły plik należący do bieżącego użytkownika bez praw grupy/innych. Lstat/open O_NOFOLLOW/fstat oraz ponowny fstat wykrywają podmianę lub zmianę podczas odczytu. Nie jest to izolacja od administratora lub złośliwego procesu działającego jako ten sam użytkownik.

Nowy klucz musi być poprawnym P-256/PKCS8; SHA256 publicznego SPKI DER musi zgadzać się z permit. CLI wiąże pola wycofywanego klucza z rzeczywistymi publicznymi metadanymi starej rejestracji:

- ID: `0663e7ddc1124c0522589f5db7d0786c19f80c35ac158199db561f6e79a80919`.
- publiczny SPKI SHA256: `8c42a2a2bcfc81ebff8ef0838923f84654ccf8dc8401777d9c26f51766e68b11`.

Nowy ID i publiczny fingerprint muszą być inne. Nie można omyłkowo wskazać starego klucza pod zmienionym polem retiredKeyID. Są to publiczne identyfikatory, bez treści prywatnego klucza. Odczytano publiczny PEM i metadane, nie używano starego klucza do podpisania próby.

Przed każdym żądaniem i przy odczycie odpowiedzi sprawdzamy aktywację oraz niezmienność permit (treść i tożsamość pliku). Obserwator250ms przekazuje abort po usunięciu/zmianie permit, utracie opt-in lub upływie okna. Silnik dodatkowo kontroluje zegar ścienny i monotoniczny, cofnięcie czasu, limit wywołań oraz deadline. Cofnięcie nie odwraca już wysłanej operacji; nieznany wynik pozostaje w dzienniku i wymaga weryfikacji.

## Raport i odzyskiwanie

Przed IO powstaje kompletny, prywatny `attempt-<windowUUID>.json` publikowany atomowo bez nadpisywania. Rezerwacja okna pozostaje również po awarii przed rozpoczęciem silnika. Istniejący raport tego okna także blokuje start. Zmiana zawartości dziennika, inwentarza, klucza lub trybu nie pozwala powtórzyć create w tym samym inwentarzu po rozpoczęciu przebiegu.

Po przebiegu zapisujemy kompletny `report-<windowUUID>.json`0600: hash/scope/okno, wynik protokołu i sprzątania, stan storage/IO, liczniki, bezpieczne kody błędów i pozostałe własne ID. Zapis używa fsync pliku, atomowego link do nieistniejącego celu oraz fsync katalogu. Nie nadpisuje dowodów operatora. Błąd publikacji raportu po żądaniach daje `incomplete`, nigdy wynik sukcesu.

Exit0 oznacza pełne potwierdzenie protokołu i sprzątania dla run; dla cleanup oznacza wyłącznie potwierdzone sprzątanie, bez podnoszenia wcześniejszego niepowodzenia protokołu do sukcesu. Exit2 to odmowa przed silnikiem, exit3 to niekompletny przebieg. Błędy nie drukują surowej odpowiedzi, PEM, ścieżki pliku ani tekstu prywatnego JSON.

Odzyskiwanie wymaga osobno zatwierdzonego świeżego okna cleanup i używa tego samego trwałego inwentarza. Nie wykonuje create, query ani forceDelete. Silnik zachowuje blokadę aż do faktycznego zakończenia IO; nieudany drain nie jest zaliczany. Sam proces CLI ma watchdog do końca okna plus8s na odpływ IO. Zatrzymuje wyłącznie siebie i zapisuje bezpieczny komunikat niepowodzenia; nie traktujemy zatrzymania procesu jako potwierdzenia nieobecności rekordów w Apple. Trwała intencja zostaje do odczytu.

## Sprawdzenie i pozostające warunki

Dodano12 funkcji testowych. Pełny gateway: **691/691 Node22.23.5 oraz691/691 Node24.22.1**. Własny proces CLI został uruchomiony z syntetycznym fetch, celowo zawieszony i zakończony przez własny watchdog; po ponownym otwarciu SQLite zachowano preflight_pending/1call i brak pozornego cleanup. Osobno sprawdzono rzeczywiste podpisy, cofnięcie/expiry po create, nowe cleanup bez drugiego create, prywatne pliki, brak nadpisywania i błędy zapisu raportu. [Dowody](evidence/community-protocol-cli-local-tests.json).

Klucze testowe były jednorazowymi niezarejestrowanymi parami syntetycznymi w prywatnych katalogach tymczasowych. Dostawca Apple jest modelem. Nie kontaktowano Apple/Cloudflare i nie zaliczono A/B, assetów, query, retencji/CDN, Free lub TestFlight. Kod produktu/iOS, zależności i CI bez zmian; kompilacji/testów iOS nie ponawiano. Następny krok wymaga konkretnego zatwierdzenia operacji z przygotowanego zakresu.
