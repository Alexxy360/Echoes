# Weryfikacja migracji CloudKit

Stan: 15 listopada 2026. **Migracja nie jest odebrana i aplikacja nie została przełączona na CloudKit.**

## CK-01c — rzeczywista konfiguracja i próba prywatna

- Po osobnych zgodach właściciela zarejestrowano jawny App ID `mpvEcho.Echo`, kontener `iCloud.mpvEcho.Echo` i powiązanie w zespole `22YC9RAP4P`. Ponowne otwarcie konfiguracji potwierdziło jeden aktywny kontener; konsola CloudKit pokazała Dev.
- Wygenerowano zgodny profil i podpisano Debug, następnie zainstalowano go na zatwierdzonym iPhonie 15 Pro (iOS 26.7.1). Instalacja aktualizowała aplikację; nie wykonywano odinstalowania ani kasowania jej danych.
- Preflight rzeczywistych uprawnień podpisanej aplikacji i embedded.mobileprovision: `entitlements-match`, Development, jawny kontener. Skrypt nadal zwraca `liveCloudKitVerified: false`, ponieważ sam nie kontaktuje się z CloudKit.
- `python3 scripts/test_cloudkit_preflight.py`: **8 testów przeszło**. Dodano rzeczywisty format zakresu usług/środowisk profilu Apple, bez dopuszczania wildcardu kontenera i bez osłabienia kontroli konkretnego podpisu aplikacji.
- Próba na prawdziwym koncie: **konto dostępne; zapis, odczyt nonce, metadane bieżącego twórcy i usunięcie własnego losowego rekordu — poprawne**. [Raport z urządzenia](evidence/cloudkit-private-probe-development.json), przebieg `60749670-DA22-4BE6-BD5B-427C5CDBC07E`, początek `2026-11-12T20:34:21Z`.
- Pierwszy przebieg również poprawnie zapisał, odczytał i usunął rekord, lecz porównanie twórcy wyłącznie z resolved userRecordID było fałszywe. Drugi raport potwierdził `creatorUsesCurrentUserAlias: true` i `creatorMatchesResolvedIdentity: false`. Diagnostyka rozpoznaje `CKCurrentUserDefaultName` tylko w tej prywatnej bazie; nie jest to nowa reguła autoryzacji publicznego klienta. Surowe identyfikatory kont nie są zapisywane w raporcie ani repozytorium.
- Wykonano dwa ograniczone przebiegi; **oba losowe rekordy usunięto**. Nie odczytywano profilu, GPS ani muzyki; nie zmieniano dawnych danych. Development utworzył wyłącznie typ/pola `EchoesAccessProbeV1`. Nie promowano schematu.
- `cktool get-teams`: brak zapisanego tokenu zarządzania. Nie tworzono ani nie eksportowano tokenu.

## CK-02b — podpisany host diagnostyczny

- EchoesCloudKit jest lokalną zależnością aplikacji. `ECHOES_CLOUDKIT_PROBE=1` działa wyłącznie w Debug, uruchamia natywne źródło konta w podpisanym hoście i pomija inicjalizację Firebase, mapę, GPS i muzykę. Nie przełącza zwykłego CommunityClient.
- Kompilacja całej aplikacji: **Debug dla urządzenia i symulatora oraz Release dla urządzenia przeszły**. Release bez podpisywania; nie jest testem produkcyjnego iCloud. Poprawiona diagnostyka autora została ponownie skompilowana, podpisana i uruchomiona na iPhonie.
- **4 testy UI demo przeszły** na wcześniej zatwierdzonym iPhonie 17 Pro Simulator. Potwierdzają brak regresji demonstracyjnych ścieżek po dodaniu zależności i przełącznika, nie działanie serwera CloudKit.
- Wcześniejsze **21 testów pakietu** nadal dotyczy konta, prywatnego profilu i przygotowania zdjęć offline. Testowano m.in. zmianę tożsamości, spóźnione odpowiedzi i bezpieczne błędy; nie wylogowywano właściciela z iCloud na urządzeniu.

## Obowiązkowe dowody przed odbiorem CK-01/CK-02

| Próba | Stan | Warunek odbioru |
| --- | --- | --- |
| Jawny App ID, kontener i profil | Potwierdzone dla Debug Development; prywatny test jednego konta przeszedł | Spójne uprawnienia portalu, podpisanej aplikacji i rzeczywistego kontenera. |
| Dwa konta A/B w Development | Oczekuje na drugie konto; iPhone potwierdzony jako operator | B nie odczyta prywatnych danych A ani nie zmieni cudzych rekordów; opisać faktyczny zakres publicznego odczytu. |
| Brak iCloud i zmiana konta na urządzeniu | Testy stubów przeszły; live niewykonany | Brak przecieku cache i poprawny komunikat w prawdziwym hoście. |
| Offline, ponowienie i konflikt | Klasyfikacja błędów przetestowana; live niewykonany | Brak duplikatów i nadpisania zmian. |
| Spójność roli i dostępu z pominięciem UI | Niewykonana | Sprawdzić bezpośrednie operacje w Development; nie utożsamiać filtrów klienta z ACL. |
| Fizyczne kasowanie i moderacja | Niezaimplementowane w CloudKit | Konkretny wykonawca i proces także bez aktywnego klienta. |

Nie wykonano promocji schematu, transferu starych danych, testów penetracyjnych, pomiaru baterii ani pełnego testu obciążeniowego. Wyniki poprzedniej implementacji Firebase są historyczne i nie stanowią odbioru CloudKit.

## CK-03a — profil i zdjęcia

Pakiet zawiera obecnie 21 przechodzących testów: wcześniejsze 8 obsługi konta, 9 nowego profilu i 4 przygotowania avatarów. Profil testowano offline ze stubem bazy: izolacja kont i starych odpowiedzi, brak cichego nadpisania, brak zapisu po nieudanym wczytaniu, nowszy schemat, nieznane pola i usunięcie własnego rekordu. To nie jest potwierdzenie ról na serwerze.

Testy avatarów tworzą wyłącznie obrazy syntetyczne: potwierdzono usunięcie GPS i informacji o aparacie, normalizację orientacji, limit boku 512/128 px i wyniku 256/32 KB oraz odrzucanie nieprawidłowego wejścia. Nie uploadowano zdjęć ani nie testowano jeszcze CKAsset z prawdziwym kontem.

## Decyzja o dostępie po próbie

Właściciel wybrał: **ograniczanie odczytu przez dodatkową usługę, najpierw zbadanie darmowego limitu**. Bezpośredni publiczny odczyt mapy/czatu nie jest zatwierdzony. Sprawdzenie dostawcy i prototyp pośrednika nie są jeszcze odbiorem jego ochrony ani zgodą na płatności.

## CK-01e — klucz S2S Development i pierwsza próba

Po konkretnej zgodzie właściciela zapisano w Apple klucz publiczny „Echoes Development gateway probe 2026-11-12” w `iCloud.mpvEcho.Echo`, wyłącznie Development. Portal potwierdził „Server-to-server key created successfully”. Klucz prywatny pozostaje lokalnie poza Git, w pliku z uprawnieniami 0600 i katalogu 0700; na tym etapie nie przekazano go Cloudflare; późniejszy transfer opisuje CK-01j. Fingerprint SHA-256 publicznego SPKI: `8c42a2a2bcfc81ebff8ef0838923f84654ccf8dc8401777d9c26f51766e68b11`. Sam identyfikator klucza nie jest potrzebny w repozytorium.

[Pierwszy raport S2S](evidence/cloudkit-s2s-probe-development-initial.json): zapis niepotwierdzony, `NOT_FOUND`, odczyt niewykonany, nieobecność testowego UUID potwierdzona podczas sprzątania. Raport nie jest pozytywnym odbiorem S2S. Odczyt listy schematu potwierdził brak typu `EchoesGatewayProbeV1`; istnieją wyłącznie `EchoesAccessProbeV1` i `Users`. Nie poszerzano odczytu o dane użytkowników. Zgłoszenie zapisu do nieistniejącego typu nie utworzyło automatycznie definicji w tej ścieżce.

Automatyczna kontrola odrzuciła próbę utworzenia trwałego typu Development jako nieobjętą wcześniejszą zgodą na klucz/rekord. Nie obchodzono blokady. Właściciel został poproszony o osobną zgodę na nowy typ, pola nonce String / schemaVersion Int64, wyłącznie serwerowy dostęp i ponowienie próby. Do czasu odpowiedzi schemat nie jest zmieniony; formularz jest jedynie przygotowany.

## CK-01f — typ, ograniczone role i udany test S2S — 13 listopada 2026

Po odrębnej zgodzie właściciela utworzono wyłącznie w Development `EchoesGatewayProbeV1`, pola `nonce: String` i `schemaVersion: Int64`. Nie dodawano indeksów do tej próby po nazwie rekordu, nie promowano schematu i nie zmieniano definicji wcześniejszych typów.

Dla nowego typu wyłączono wszystkie prawa standardowych ról: `_world`, `_icloud`, `_creator`. Odświeżone widoki po zapisie potwierdziły brak tego typu w przypisaniach tych ról. [Udokumentowana konfiguracja](evidence/cloudkit-gateway-probe-schema-development.json) jest zapisem obserwacji, nie importowalnym schematem Apple ani automatycznym audytem całego kontenera.

Próba po samym odebraniu praw klientom zwróciła **ACCESS_DENIED również dla S2S**, z potwierdzoną nieobecnością losowego rekordu: [raport odmowy](evidence/cloudkit-s2s-probe-development-denied.json). Skorygowano wcześniejsze założenie o automatycznym omijaniu ról. S2S dziedziczy prawa twórcy klucza, co potwierdza [przykład Apple](https://developer.apple.com/go/?id=cloudkit-catalog).

Dodano rolę `EchoesGatewayProbeService`, prawa Create/Read/Write wyłącznie dla `EchoesGatewayProbeV1`. Z bieżącej tożsamości klucza (`users/caller`) odczytano tylko identyfikator potrzebny do przypisania. W konsoli pobrano wyłącznie odpowiadający mu rekord Users i przypisano tę rolę; nie zmieniono pól profilu, definicji Users ani ról innych użytkowników. W repozytorium znajduje się tylko hash identyfikatora, bez surowego userRecordName i danych osobowych.

**Końcowy wynik: zapis, odczyt poprawnego nonce i schemaVersion oraz usunięcie — wszystkie poprawne.** [Raport rzeczywisty](evidence/cloudkit-s2s-probe-development.json): przebieg `4899adac-afe0-45a4-92f3-d3b426733f7c`, `2026-11-13T08:58:09.014Z`. Rekord został usunięty. Nie odczytywano mapy, czatu, GPS, muzyki ani prywatnego profilu.

Przypisanie roli dotyczy konta, nie wyłącznie pliku klucza. Urządzenie zalogowane jako ten operator również ma jego prawa. Przed produkcją wymagana jest oddzielna tożsamość serwisowa i test natywnych, nieuprzywilejowanych kont A/B; nie deklarujemy jeszcze ich odbioru. Wcześniejszych domyślnych ról innych typów nie zmieniano.

Klucz zachowano w trwałym lokalnym katalogu poza wszystkimi worktree Git (katalog 0700, pliki 0600), aby nie polegać wyłącznie na plikach tymczasowych. Na tamtym etapie nie przekazano go Cloudflare; późniejszy transfer opisuje CK-01j. Nie uruchomiono płatności. Test lokalny nie jest jeszcze testem pośrednika sieciowego ani limitem CPU Workers.

## CK-01g — lokalny prototyp Workers

Przeszło 25 testów Node 22 (12 wcześniejszych, kontekst, 6 HTTP i 6 rezerwacji SQLite). Dodatkowo sprawdzono składnię MJS. Są to testy lokalne SQLite/Node, nie runtime Cloudflare. Stan historyczny CK-01g: prototyp był wyłączony, niewdrożony i bez transferu sekretu. Aktualizację zawiera CK-01j. Npm/curl nie połączyły się poprawnie z oficjalnym registry.npmjs.org; instalacja Miniflare nie nastąpiła. [Zakres i dalsze próby](WORKERS_DIAGNOSTYKA.md).

## CK-02c — porównanie konta urządzenia z tożsamością serwera

13 listopada 2026 skompilowano i podpisano Debug, zaktualizowano zatwierdzoną aplikację na ponownie podłączonym iPhonie 15 Pro bez odinstalowania/danych i uruchomiono osobną kontrolę konta. Wymagała odblokowania ekranu przez właściciela. [Raport rzeczywisty](evidence/cloudkit-identity-check-device.json) potwierdza dostępne konto zgodne z kontem twórcy klucza. Nie odczytano profilu ani rekordów aplikacji, GPS lub muzyki; wynik zawiera wyłącznie UUID/czas i booleany.

Właściciel potwierdził, że obecnie dysponuje tylko tym kontem. Konta operatora nie używamy jako dowodu odmowy dla zwykłego użytkownika. Natywna próba A/B pozostaje otwarta; nie wylogowywano właściciela i nie zmieniano Apple ID. Odbiór przed publikacją nadal wymaga osobnego, nieuprzywilejowanego konta testowego.

## CK-01h — stan Cloudflare przed publikacją prototypu

Utworzono pustą usługę echoes-development-probe z domyślną odpowiedzią Hello World. Plan Free / Current plan / $0 potwierdzono ponownie w panelu 13 listopada. Brak sekretów, bindings i dostępu do CloudKit. [Zapis obserwacji](evidence/cloudflare-development-worker-bootstrap.json). Automatyczna kontrola zatrzymała dodanie pierwszego pliku do zdalnego edytora jako niezatwierdzoną modyfikację aktywnej usługi. Na tym etapie kod prototypu nie był wdrożony; późniejsze zgody i działania opisuje CK-01j. Nie zmieniono CloudKit Production ani nie uruchomiono opłat.

## CK-01j — 2026-11-13 — wdrożenie diagnostyki i poprawka zgodności Workers

Po wyjaśnieniu roli Cloudflare właściciel jednoznacznie zatwierdził kod, SQLite, klucz Development jako sekret oraz jedną próbę. Osobno zatwierdził tymczasowy token wdrożenia ograniczony do tej jednej usługi. W panelu potwierdzono Individual Workers Editor / echoes-development-probe, bez uprawnień do innych usług; ustawiono okno około 2 h. Nie zmieniono planu Workers Free, CloudKit Production ani danych użytkowników.

Kod opublikowano w Dashboard, a klasę DevelopmentProbe utworzono przez oficjalne API z new_sqlite_classes / v1. Pierwszy upload API odrzucił błędną nazwę części multipart (No such module: worker.js); poprawienie filename=worker.js pozwoliło wdrożyć klasę SQLite. Metadane zwróciły startup_time_ms=4 — to czas startu, nie pomiar CPU żądania. Runtime HTTP potwierdził 200 /health, 503 dla wyłączonej próby, 405 dla metody i 404 dla obcej trasy. Po aktywacji bez klucza Apple potwierdzono 401 bez tokenu, 400 dla obcego wejścia i 503 diagnostic-disabled z Durable Object. Żaden z tych preflightów nie wykonuje operacji CloudKit. [Raport wyłączonego HTTP](evidence/workers-disabled-http.json), [preflight runtime](evidence/workers-runtime-preflight.json).

Następnie przesłano klucz wyłącznie do sekretu CLOUDKIT_PRIVATE_KEY tej usługi i wykonano jeden POST /probe. Wynik: HTTP 502, TRANSPORT_FAILED przy create i cleanup. Trwała rezerwacja zachowała RUN_ID i kontekst; nie skasowano jej ani nie ponowiono zapisu pod nowym UUID. [Raport próby](evidence/workers-cloudkit-probe-failed.json). Lokalny podpisany lookup tego dokładnego UUID zwrócił NOT_FOUND: rekord nie pozostał w Development. [Potwierdzenie nieobecności](evidence/workers-cloudkit-probe-absence.json). To nie jest sukces testu Cloudflare → CloudKit.

Przyczyna: użyty redirect:error jest zgodny z Node, ale Workers rzuca TypeError przy konstruowaniu Request, zanim wyśle żądanie. Poprawka ustawia manual; istniejący odczyt odpowiedzi odrzuca 3xx bez podążania za Location. [Oficjalna dokumentacja Request](https://developers.cloudflare.com/workers/runtime-apis/request/). Dodano regresję z dwoma rzeczywistymi serwerami loopback: cel przekierowania nie otrzymuje żadnego żądania ani podpisanych nagłówków, create nie jest ponawiane.

Dodano też bramkowany tym samym tokenem, UUID i terminem PROBE_LOCAL_CHECK_ONLY: samo skonstruowanie podpisanego żądania wewnątrz DO, bez fetch, SQLite i eksportu podpisu/klucza/treści wyjątku. To pomoc do odbioru runtime przed następnym zapisem. Pierwsze wdrożenie tego trybu po wznowieniu pracy odrzuciło 401, ponieważ poprzedni token zdążył wygasnąć; nie przedłużano go automatycznie.

Poprzednia aktywacja wygasła. Po wznowieniu pracy ustawiono także jawne PROBE_ENABLED=0 i usunięto CLOUDKIT_PRIVATE_KEY oraz PROBE_BEARER_TOKEN z aktywnej wersji. Wygasły token API usunięto w panelu, a lokalne tymczasowe kopie sekretów usunięto z /private/tmp. Oryginalny klucz Apple pozostaje w chronionym Application Support. Usunięcie bindingów aktywnej wersji nie jest deklaracją wyczyszczenia historii wersji dostawcy ani unieważnienia S2S w Apple; tego klucza Apple nie odwołano. Rezerwacja SQLite pozostaje jako dowód wykonania, nie jest czyszczona do ponowienia.

Weryfikacja poprawki: 27 testów Node 22 przeszło, składnia wygenerowanego pliku poprawna. Test loopback początkowo zablokował sandbox (listen EPERM), a po dopuszczeniu lokalnych portów przeszedł cały zestaw. Nie instalowano zależności i nie wyłączano TLS. Npm pozostaje niedostępny z tej sieci; wdrożenie używało panelu/oficjalnego API. Pełny test S2S po poprawce, pomiar CPU i A/B nadal wymagają odbioru; nie zmieniono aplikacji iOS ani adaptera Firebase.

Poprawiony pakiet opublikowano przez Dashboard jako aktywną wersję `476028fa`, przy PROBE_ENABLED=0 i bez obydwu sekretów. Publikacja kodu nie jest dowodem ukończenia próby S2S po poprawce.

## CK-01k — udany test Workers → CloudKit Development

Po osobnej zgodzie na jedną próbę do 30 min kontrola bez sieci wykryła niezgodny KeyObject w options.key. Po zachowaniu walidacji P-256 i użyciu PEM podpisanie Request w Workers przeszło. Następnie rzeczywisty zapis, odczyt i usunięcie jednego rekordu przeszły (HTTP 200); ponowienie tego samego RUN_ID zwróciło zapisany raport. [Wynik S2S](evidence/workers-cloudkit-probe-success.json), [wynik ponowienia](evidence/workers-probe-replay.json), [szczegóły i ograniczenia](WORKERS_DIAGNOSTYKA.md#ck-01k--2026-11-13--zaliczona-próba-workers--cloudkit).

Próbę wyłączono, sekrety usunięto z aktywnej wersji, potwierdzono 503 bez tokenu. Bez nowego tokenu wdrożenia i bez opłat. Wszystkie 27 testów Node przeszło po poprawce. Zagregowane metryki małej diagnostyki nie wykazały przekroczeń CPU; nie zastępują testu obciążenia ani pomiaru DO. A/B, odrębna tożsamość produkcyjna i logowanie użytkowników nadal oczekują. Oryginalny klucz Apple nie jest odwołany, a usunięcie bindingów aktywnej wersji nie oznacza purgowania historii hostingu.

## CK-02d — lokalna weryfikacja Apple identity tokenów

13 nowych testów na syntetycznych RSA/JWT przeszło, a cały gateway ma 40 przechodzących testów. Sprawdzono niezależny podpis, alg/issuer/aud/nonce/czasy, format i rozmiar tokenu, redakcję claims, stały host kluczy, cache/rotację/współbieżność, brak wygasłego cache podczas awarii i odrzucanie przekierowań. Nie używano prawdziwego ID tokenu, danych konta ani sieci w testach. Publiczną konfigurację OpenID/JWKS Apple odczytano osobno jako podstawę protokołu. Nie wdrożono tych modułów w Workers ani nie zmieniono iOS. [Granice i kryteria](APPLE_LOGOWANIE_GATEWAY.md).

## CK-02e — wyzwania i sesje SQLite

17 nowych testów przeszło; cały zestaw ma 57. Prawdziwy lokalny SQLite potwierdza jedną wymianę kodu i sesję przy równoległości, zachowanie claimed po ponownym otwarciu, limity i wygaśnięcie, trwałe wylogowanie/blokadę, rollback oraz brak tokenów/nonce/sub w tabelach. ID tokeny/RSA są syntetyczne; adapter wymiany kodu jest testowy, bez sieci. Bez wdrożenia/nowego zasobu i zmian iOS. [Dowody i ograniczenia](SESJE_I_WYZWANIA_GATEWAY.md).

## CK-02f — OAuth i zaszyfrowane credential lokalnie

80/80 testów gateway, w tym 23 nowe: 10 OAuth, 6 AES-256-GCM i 7 integracyjnych SQLite/logowania (24 razem w tej grupie). Niezależnie zweryfikowano podpis ES256 raw, ograniczenia transportu, szyfrowanie i kontekst, rotację klucza w pamięci, zapis pending/bound, awarie i odtworzenie. Odpowiedzi Apple są syntetyczne; brak rzeczywistego kodu/refresh/revoke i zmian chmury/iOS. To dowód lokalnej implementacji, nie zaliczenie prawdziwego logowania ani Workers CPU. [Raport](evidence/apple-oauth-vault-local-tests.json), [kontrakt i pozostały odbiór](APPLE_OAUTH_I_TOKENY.md).

## CK-02g — odnowienie i retencja lokalnie

116/116 testów gateway, w tym 36 nowych: 29 integracyjnych, 3 verifiera refresh, 4 HMAC. Testy odtwarzają replay po wielu rotacjach, współbieżność/dwa granty, dobową kontrolę, późny sukces/błąd po logout/blokadzie/relogin, SQL/sync i zachowanie pending ciphertext, reopen z oddzielnymi kluczami, limity i bounded cleanup. Transport Apple syntetyczny, SQLite rzeczywiste lokalne. Nie jest to dowód A/B, prawdziwego Apple/Keychain ani Workers CPU. Bez zmian usług, sekretów, iOS i kosztów. [Raport](evidence/session-renewal-local-tests.json), [kontrakt i pozostały odbiór](ODNAWIANIE_SESJI_GATEWAY.md).

## CK-02h — lokalne zlecenie usunięcia

139/139 testów gateway, w tym 23 nowych usuwania. Rzeczywisty lokalny SQLite/verifier i syntetyczne tokeny; publiczny magazyn danych jest jawnie testowy w pamięci. 205 rekordów sprawdza sterowanie partiami i izolację, nie API CloudKit. Sprawdzono purpose, świeży dowód, quota/ban, ticket recovery, SQL/sync, drain, prywatny ack, retry i manual Apple, timeout, lease, późne logowanie, migrację starego magazynu, reopen i metadane blokad. Brak rzeczywistych danych użytkowników, sieci Apple/Cloudflare, kosztów i wdrożenia. [Raport](evidence/account-deletion-local-tests.json), [granice](USUWANIE_KONTA_GATEWAY.md).

## CK-02i — lokalne HTTP, limity i alarm

163/163 testów, 24 nowe (13 HTTP/runtime, 11 limitów/alarmu). Użyto realnych klas OAuth/JWT/SQLite i jawnych test doubles platformy, Apple oraz public erasure. Zweryfikowano route/schema/body/bearer, utrzymanie jednej authority, spoofing nagłówków, kod konfiguracji i expiry, cały przepływ sesji/usuwania, trwałe limity, fair cursor/reopen i cleanup bez kluczy. Nie jest to workerd, rzeczywisty alarm/request.cf ani pomiar CPU/SQL. Nie utworzono namespace/usługi/sekretów, nie wdrożono iOS ani zmian CloudKit. [Raport](evidence/gateway-http-local-tests.json), [kontrakt i dalszy odbiór](BRAMKA_HTTP_DEVELOPMENT.md).

## CK-03b — przestrzeń konta i bariera prywatnego usuwania

90/90 testów pakietu Swift na macOS, w tym 18 nowych. Testowano syntetyczny transport z modelem atomowych wersji: izolacja kont i przestrzeni, świeża autoryzacja, wyścig zapisu/usunięcia, 206 rekordów, strony/kursory, restart, legacy oraz niepewne wyniki. Debug i Release skompilowane dla iOS Simulator z projektem z Git. Nie wykonano operacji SDK CloudKit ani nowej instalacji na telefonie; realna atomowość/CKAsset/zmiana iCloud i A/B niezaliczone. Guard pozostaje, retencja i bilet/ACK jeszcze niegotowe. [Pełny zakres](PRYWATNE_DANE_KONTA.md), [dowody](evidence/private-account-data-local-tests.json).

## CK-02m — odzyskiwanie usuwania i natywny kontrakt

196/196 Node (16 nowych), 98/98 Swift (8 nowych). Lokalna rotacja wąskiego biletu, właściwy cel dowodu, owner/account, równoległe wyzwania, utrata odpowiedzi, SQL/sync/reopen/migracja, receipt i zamknięty HTTP. Natywnie testowano token/format/redakcję, kontrakt, aktywację i sprzeczne statusy. Debug/Release skompilowane z projektem z Git. Bez prawdziwego Apple/Workers/CloudKit lub nowej instalacji. Keychain biletu, sterownik/cleaner/ACK/UI nadal niepołączone; nie jest to odbiór całego usuwania. [Zakres](ODZYSKIWANIE_USUWANIA_KONTA.md), [raport](evidence/deletion-recovery-local-tests.json).

## CK-02n — trwałe kroki natywnego usuwania

125/125 Swift (27 nowych), model API/strefy i połączenie sterownika z NativePrivateProfileDatabase. Obejmuje restart, utracone odpowiedzi/zapisy, checkpointy i wyścigi odzyskiwania; nie zastępuje SDK CloudKit. Debug/Release skompilowane z projektem z Git; syntetyczny Keychain zaliczony w podpisanym ad-hoc hoście Debug symulatora po odrzuceniu wersji bez entitlement (-34018), bez konta/HTTP i bez deklaracji odbioru wizualnego. Natywny host/arkusz/UI, realne callbacki plików, retencja i provider/A-B nadal wymagane. [Kontrakt](TRWALY_BILET_USUWANIA.md), [raport](evidence/deletion-flow-local-tests.json).

## CK-02o — host usuwania, lokalne pliki i kontrolny UI

151/151 Swift (26 nowych), 9/9 XCTest UI (5 nowych i 4 demo) na iPhone 17 Pro/iOS Simulator 26.1. Natywna tożsamość, API i strefy są jawnie modelowane; test plików korzysta z własnych losowych katalogów tymczasowych. Testowano selektywny fence, późne logowanie/odnowienie, potwierdzenia, zdarzenia konta, wznowienie i błędy storage; UI obejmuje anulowanie/wykonanie alertu, własne checkpointy, unconfigured i Accessibility XXXL. Finalne zrzuty obejrzano. Debug ad-hoc i Release bez podpisywania skompilowane z projektem z Git; po nich zmieniono tylko komentarze w dwóch plikach i zaliczono strict lint. Release bez markerów kontrolnych/aktywacji. Nie ponawiano realnej próby Keychain CK-02n; bez prawdziwego Apple/CloudKit/Workers/A-B, danych użytkowników lub publikacji. Zwykły adapter nadal Firebase. [Kontrakt i nieudane wcześniejsze przebiegi](NATYWNE_USUWANIE_UI.md), [raport](evidence/deletion-host-local-tests.json).

## CK-02p — świadome porządkowanie lokalnych potwierdzeń

162/162 Swift (11 nowych: 8 sterownika, 3 hosta) i 10/10 UI (1 nowy). Snapshot/rotacja, własne checkpointy, tożsamość, zapis po odblokowaniu, pełny dziennik, brak wywołań gateway/cleanera i brak odtworzenia przez późną odpowiedź. Nowy UI test anuluje i zatwierdza lokalne usunięcie bez nowego arkusza Apple; zrzuty obejrzano. Pierwsza nowa asercja źle modelowała osobną session — korektę opisuje [kontrakt](LOKALNE_POTWIERDZENIA_USUWANIA.md). Testy używają modelu storage/konta/API; rzeczywistego Keychain i provider/A-B nie ponawiano. Bez zmian usług/danych użytkowników, automatycznego TTL i prywatnego guarda. [Raport](evidence/deletion-receipt-local-tests.json).

## CK-04a — transport publicznych rekordów, trwały rejestr i erasure

217/217 na Node 22.23.5 i 24.22.1 (21 nowych: 20 repozytorium/transportu/rejestru i 1 kompozycji runtime/HTTP). Rzeczywiste lokalne SQLite/crypto, niezależne verify podpisów oraz model CloudKit bez indeksów, nigdy realny provider. Obejmuje utratę odpowiedzi, restart adaptera, późny create/replace po barierze, owner/generację/lease, 52 rekordy wszystkich etapów, wszystkie pięć typów, częściowy wynik, dodatkowe pola, deadline/cancel i limity 1000/10000. Weryfikacja składni 49 MJS i JSON. Node 22 pobrany z oficjalnego nodejs.org, SHA-256 zweryfikowane; bez instalacji systemowej. Źródła iOS/Swift, schemat/róle/usługi/sekrety i Production niezmieniane; testów iOS nie ponawiano. Wymagane przed uruchomieniem: ochrona utraty/cofnięcia rejestru, retencja barier, pełny koordynator funkcji, realne SDK/Workers/róle i A/B. [Kontrakt](SERWEROWY_ADAPTER_DANYCH.md), [raport](evidence/public-records-local-tests.json).

## CK-04b — outbox punktu kontrolnego i cofnięcie SQLite

234/234 Node 22.23.5 oraz 24.22.1 (17 nowych: 12 checkpoint i 5 HTTP/runtime), składnia 52 MJS i JSON. Spójne snapshoty własnych syntetycznych tabel w rzeczywistym lokalnym SQLite, modele CloudKit/Apple: bootstrap brak/utrata odpowiedzi, exact pending, write/sync failure, reset epoki, fork z równą liczbą rekordów, odmowa false erasure, obie kolejności opóźnionego CAS oraz cofnięcie logout-all. Sprawdzono limit przed checkpoint network i odmowę auth-only po założeniu epoki. Kontrola negatywna po wyłączeniu pojedynczego porównania w /tmp wykryła trzecią rezerwację zamiast dwóch; właściwe źródła niezmienione i zielone. To nie jest Cloudflare PITR/CPU/SQL ani odbiór ról/A-B. Nie zmieniano usług/uprawnień/sekretów, danych użytkowników lub Production; źródła iOS identyczne, kompilacji nie powtarzano. [Kontrakt i wymagania](PUNKT_KONTROLNY_REJESTRU.md), [raport](evidence/registry-checkpoint-local-tests.json).

## CK-04c — serwerowe funkcje społecznościowe

256/256 Node 22.23.5 i 24.22.1 (22 nowe: 20 funkcji/polityki/HTTP, 2 runtime), składnia 57 MJS i JSON. Testy na rzeczywistym lokalnym SQLite/crypto i jawnie modelowanych CloudKit/Apple. Publish/stop w obu kolejnościach, utracone odpowiedzi, natychmiastowe blokady obu stron i zmiana w ostatnim checkpoint, moderacja/sesja/autor, 125 wiadomości, poufny cursor z kontem/obszarem/czasem, knownIDs, 3 km, 500 m i dateline/bieguny, wygaśnięcie bez fizycznego TTL, rate/capacity, profil CAS, poufne zgłoszenie oraz cleanup właściciela po disable/restart. Kontrola negatywna w osobnej kopii wyłącza pojedynczy końcowy guard polityki; test HTTP wówczas ujawnia wiadomość i rzeczywiście upada. Właściwe źródła zielone. Nie zmieniano Swift/UI/projektu i nie powtarzano kompilacji iOS; brak realnych usług/typów/indeksów/ról/sekretów lub danych użytkowników. [Kontrakt i braki odbioru](FUNKCJE_SPOLECZNOSCIOWE_GATEWAY.md), [raport](evidence/community-local-tests.json).

## CK-04d.1 — natywny typowany kontrakt

171/171 EchoesCloudKit na macOS (9 nowych), 256/256 Node 22.23.5 i 24.22.1. Swift konsumuje 13 par rzeczywistego lokalnego HTTP/SQLite/podpisanego modelu CloudKit; nie jest to provider acceptance. Testy obejmują strony ponad 32 KiB, bounds/daty/duplikaty/order/zasięg/removedIDs, ack także po expiry, błędy, input bez dispatch, aktywację/cancel i rzeczywisty Foundation streaming przez URLProtocol. Debug ad-hoc Simulator oraz Release iOS bez podpisywania zielone; wcześniejszy błąd niepełnego cache udokumentowany, bez zmiany bibliotek. Strict format 5 plików, syntax 58 MJS/JSON. Oba app bundles bez aktywacji i fixtures/test bundle. Nie zmieniano UI; nie ponawiano jego testów. Brak rzeczywistych usług/A-B/Keychain journal, opłat/publikacji. CommunityClient/journal i pełna integracja produktu pozostają do wykonania. [Kontrakt](NATYWNY_KONTRAKT_SPOLECZNOSCIOWY.md), [raport](evidence/native-community-contract-tests.json).

## CK-04d.2 — adapter, journal i izolacja kont

190/190 EchoesCloudKit (19 nowych) i 22/22 Core (9 nowych), oba wykonane na macOS. 257/257 Node 22.23.5/24.22.1 (1 nowy CAS); aktualne 14 par JS/Swift. Restart/unknown ack, storage przed/po sieci, scope/lease/ABA, natywny hostcredentials i stare rejection, owner ack, stop/rates/report ID, capacity, Core account/tło/delete/draft/old-area/cursor. Negatywna kopia bez pojedynczego block generation guard przyjmuje stary blok i rzeczywiście oblewa test po upływie limitu rate. 10/10 istniejących UI testów na iPhone 17 Pro Simulator 26.1 (4 demo, 6 usuwanie), bez zwykłych providerów. Rzeczywisty Keychain signed ad-hoc na tym symulatorze: nowe lease odtwarza pending send, attributes/size, rozdział A/B, exact cleanup i końcowe usunięcie własnych losowych slotów; natywna tożsamość i HTTP jawnie modelowane. Obejrzano końcowy ekran passed i przechwycono console-pty community/storage/deletion result=passed; wcześniejszy stdout redirect nie był dostępny. Brak fizycznego lock/reboot/backup/restore i realnych providerów. Strict lint 13 plików, syntax 58 MJS/JSON. [Kontrakt](NATYWNY_ADAPTER_SPOLECZNOSCIOWY.md), [raport](evidence/community-client-local-tests.json). Native UI/AppServices i reszta pełnego planu nadal w toku; brak aktywacji i publikacji.


## CK-04d.3 — kontrolowany host mapy/czatu

196/196 EchoesCloudKit (6 nowych) na macOS: izolacja prezentacji, revision/wygaśnięcie, late close, unknown send bez auto retry i wpięcie prawdziwego hosta auth z modelowanymi źródłami. Pełny przebieg 16/16 XCTest UI (4 demo, 6 nowych natywnych, 6 usuwania) na zatwierdzonym iPhone 17 Pro Simulator/iOS26.1. Przegląd PNG po zielonym przebiegu ujawnił overlap syntetycznego banera ze szkicem przy AX XXXL; po zmianie układu ponowiono 10/10 dotkniętych testów demo/community, dodając sprawdzenie geometrii. Pozostałe 6 testów usuwania i ich przepływ nie zmieniły się. Końcowe PNG obejrzane, bez edycji: [mapa](evidence/community-host-map.png), [recovery i edytowany szkic](evidence/community-host-pending.png), [alert z Anuluj](evidence/community-host-forget.png), [duży przewijany układ](evidence/community-host-large-text.png), [przejście do konta](evidence/community-host-account-route.png).

Debug ad-hoc i końcowy Release iOS bez podpisywania zielone, strict format 18 Swift. Pakiety bez bundled aktywacji/test resources, Release bez trzech debug flag; uwzględniono osobny Echoes.debug.dylib w kontroli Debug. Gateway i EchoesCore identyczne z baseline, więc nie ponawiano niezmienionych testów (poprzednio 257/257 Node22/24 i 22/22 Core). Nowa kompozycja używa rzeczywistego klienta/Domain/Host, ale tożsamości/API/storage są jawnie syntetyczne. MapKit może pobierać mapę, UserAnnotation/sensory w podglądzie odcięte. Nie zaliczono realnego logowania, ról/odległości/CloudKit/Workers lub fizycznego Keychain. Wczesne błędy kompozycji/fixture/helpera i przerwane przebiegi nie są odbiorem; końcowe wyniki oraz SHA są w [raporcie](evidence/community-host-local-tests.json). [Kompozycja i ograniczenia](KONTROLOWANY_WIDOK_SPOLECZNOSCIOWY.md). Bez nowych usług, sekretów, opłat, danych użytkowników i publikacji; pełna migracja nadal w toku.


## CK-04e.1 — prywatny pseudonim połączony z iOS

204/204 EchoesCloudKit (8 nowych) oraz 22/22 XCTest UI (6 nowych), Debug ad-hoc Simulator i Release iOS bez podpisywania. Swift obejmuje obowiązkową autoryzację przed providerem, cancel, clear/reload/save/delete/defer w tej samej przestrzeni, konflikt/unknown i jawne odzyskanie. UI obejmuje nowy Store/prezentację, brak importu starego pseudonimu/zgody, offline, konflikt i unknown z zachowaniem szkicu i aktywnej nazwy, późne A→B oraz AX XXXL. Sześć PNG obejrzane bez edycji; in-memory model rewizji nie dowodzi rzeczywistego CKRecord change tag ani persistence po restarcie procesu. Pierwszy pełny zestaw UI zielony; początkowy brak importu nowego komponentu poprawiony po kompilacji.

Strict format 10 Swift, pakiety bez aktywacji/test resources, Release bez debug flags. Nie zmieniono Gateway/Core, ich testów nie powtarzano. Inwentarz urządzeń tylko odczytano; brak instalacji/SDK mutacji na telefonie i zmian usług/schema/ról. Nowy Runtime używa właściwego adaptera SDK, ale rzeczywisty profil/guard/CAS/cleanup, SIWA/Free/A-B i CKAsset nadal wymagają odbioru. [Kontrakt i PNG](TRWALY_PSEUDONIM_IOS.md), [raport ze źródłami/SHA](evidence/private-profile-ui-local-tests.json), [następne zdjęcia](PLAN_AVATAROW_CLOUDKIT.md). Migracja nie jest ukończona.


## CK-04e.2a — przygotowana diagnostyka SDK, bez aktywacji

212/212 Swift (8 nowych), 8/8 powtórzonych po zmianie dwóch nazw testów; 2/2 UI (1 nowy) i obejrzany ekran nieaktywnego testu na zatwierdzonym Simulatorze. Debug Simulator, podpisany Debug dla istniejącego telefonu oraz Release bez podpisywania zielone. Odczyt podpisu i embedded profile potwierdził Development/kontener/zespół; bez aktualizacji profilu i bez instalacji. Release nie zawiera markerów nowej diagnostyki, pakiety bez konfiguracji aktywacji. Strict lint 7 Swift. [Raport ze źródłami/SHA i wcześniejszą poprawką podpisywania](evidence/private-profile-sdk-preparation.json).

Przygotowano [konkretny zakres próby](PRIVATE_PROFILE_SDK_DIAGNOSTYKA.md): własne dwie strefy, syntetyczny profil, SDK conflict/guard i exact cleanup. Bez nowej zgody test nie został uruchomiony. Lokalne testy i właściwy podpis nie dowodzą rzeczywistego SDK, ról, dwóch kont ani ukończenia migracji. Gateway/Core i usługi niezmienione.


## CK-04e.3a — natywna granica renderowania zdjęć

221/221 Swift (9 nowych), strict lint 2 plików, Debug ad-hoc Simulator i Release bez podpisywania. Rzeczywiste kodowanie i dekodowanie ImageIO z lokalnymi JPEG/PNG, wyniki AvatarPreparer, błędne manifesty/wersje/wymiary/hashe i anulowanie. Brak zmiany UI, transportu lub Gateway/Core, więc ich testów nie ponawiano. Pakiety bez aktywacji. Nie pobierano zdjęć przez sieć, nie wykonywano CKAsset/SDK, nie mierzono Free i nie zaliczono ról/A-B. [Kontrakt i wymagania integracji](AVATAR_ODBIOR_PLIKOW_IOS.md), [raport i SHA](evidence/avatar-payload-local-tests.json). Zgłoszona zgoda SDK jest nadal odrębną sprawą; migrowana aplikacja nie jest gotowa do TestFlight.


## CK-04e.2b — rzeczywisty prywatny profil/konflikt/cleaner

Zatwierdzony iPhone 15 Pro/iOS26.7.1, Development/private, pierwszy runID `b658e6a1-959d-4661-8ef4-bd85358641ab`, start 11:56:30 UTC. SDK potwierdziło zapis/odtworzenie przez nowy Store, change tag, `serverRecordChanged` (14) przy starej kopii, rozdział dwóch własnych przestrzeni na jednym iCloud, cleaner i guard. Obie nowe strefy usunięte i nieobecność sprawdzona SDK. [Raport pobrany z chronionego pliku](evidence/private-profile-sdk-device-result.json) zgodny z konsolą; [podpisy, SHA, deaktywacja i granice](evidence/private-profile-sdk-device-verification.json). Nie uruchamiano drugiej/trzeciej próby. Po wyniku zainstalowano czysty podpisany pakiet bez aktywacji i nie uruchamiano go. Brak nowych kluczy/profili, usług, kosztów i Production. Źródła natywne niezmienione, lokalnych testów nie ponawiano.

Odczyt pliku po wymianie aplikacji zwrócił EPERM; nie zaliczono retencji/markera po reinstalacji. Nie jest to dowód restartu procesu, A/B zwykłych kont, prawdziwej sesji gateway/biletu/ACK ani CKAsset/Free/ról. Definicje typów zaakceptowane przez SDK, bez osobnego przeglądu konsoli. Pełny cel nadal w toku.


## CK-04e.3b — lokalna trwałość i transport uploadów

286/286 Node22.23.5 oraz Node24.22.1, 29 nowych, składnia 60 MJS/3 JSON. Rzeczywiste lokalne SQLite/crypto/checkpoint, jawne modele Apple/assetów: trwały claim, równoległość/reopen/unknown/rollback, brak sekretów w SQL/uchwycie i nagłówkach drugiego requestu, zamknięty URL/receipt, 16 KiB/8 s/abort, erasure w trakcie i po uploadzie, dołączone modelowe assety, SQL failure bez false ACK. Błędy pierwszych fixtures i ograniczenia sandbox-localhost opisano w [raporcie/SHA](evidence/avatar-assets-local-tests.json). Końcowe dwa przebiegi zielone; nie jest to prawdziwy CKAsset lub Workers Free.

Nowy moduł nie jest importowany przez runtime ani HTTP; lista rzeczywistych hostów pusta, flagi 0. Bez usług/schematów/ról/sekretów/kosztów/Production. Brak zmian Swift i powtarzania iOS. Serwerowa walidacja JPEG, przypięcie/odzyskanie receipt, moderacja/CAS profilu, odczyt/cache i fizyczna retencja nadal niegotowe. [Kontrakt i granice](UPLOAD_AVATAROW_GATEWAY.md). Wcześniejszy prywatny test SDK nie zalicza publicznych assetów lub dwóch kont.


## CK-04e.3c — normalizacja zdjęć i interoperacyjność

301/301 Node22.23.5 i Node24.22.1 (15 nowych: 14 normalizacji/binding i 1 rzeczywistego workerd/DO/SQLite), czyste npm ci bez install scripts, końcowy audit zero znanych podatności. 222/222 Swift (1 nowy): dokładne serwerowe JPEG przechodzą native manifest/hash/ImageIO, kontrolę pikseli i braku metadanych. Przypięte Wasm: MozJPEG dekoder i Rust enkoder, pełny decode/reencode oraz miniatura z tych samych pikseli; zamknięty baseline intake i owner/version/request, limity, warning/fatal odmowa i recovery. Statyczne moduły i licencje w repo. Testy używają syntetycznych fotografii, bez realnego uploadu.

Lokalny workerd 1.20260730.1/compatibilityDate 2026-07-30 wykonał normalizację w DO z rzeczywistym lokalnym SQLite i zablokowanym outbound. Nie jest to hosted Free acceptance. CPU 10 ms dotyczy edge; kodek przeznaczony do istniejącego DO (domyślnie 30 s CPU). Pomiary Maca, ograniczenia pamięci/cancel i poprawione wcześniejsze próby opisuje [kontrakt](SERWEROWA_NORMALIZACJA_AVATAROW.md), [raport/SHA](evidence/avatar-normalizer-local-tests.json) oraz [benchmark](evidence/avatar-normalizer-local-benchmark.json).

Moduł nadal bez importu z runtime/HTTP, hosty uploadu puste, flagi 0. Bez usług/schema/ról/sekretów/kosztów/Production lub ponawiania prywatnego SDK. Nie zmieniano produktu Swift/UI/Core/projektu i nie powtarzano ich buildów/UI. Pozostają receipt/recovery i rekord wersji, moderacja/CAS, produkcyjny bounded intake, chroniony odczyt/cache, retencja oraz realne Free/CloudKit/A-B; pełna migracja nadal trwa.


## CK-04e.3d — wersje zdjęć i trwałe odzyskiwanie

329/329 Node22.23.5 i Node24.22.1, 28 nowych (22 rekordu/recovery, 6 vault), końcowe pełne przebiegi po rozszerzeniu migracji i związaniu właściciela także w transporcie assetów. Rzeczywiste lokalne Wasm/SQLite/crypto/checkpoint, model Apple/tożsamości. Utworzenie niezmiennego rekordu wyłącznie create, odczyt i kontrola metadanych/obu assetów przed settled, bez publikacji profilu. Zaszyfrowane receipts AES-GCM/HKDF z ograniczonym terminem i AAD konta/operacji/pliku umożliwiają wznowienie przed create bez reuploadu. Atomic claim mask wykrywa utratę wiersza transferu; legacy pozostaje zużyte i erasable.

Odebrano lokalnie lost ACK, restart, częściowy znany i nieznany upload, expiry, nową generację logowania, współbieżność i oba porządki erasure/create, sync failure oraz rollback. Negatywna kopia bez jednego porównania provider fileChecksum oblewa test. workerd/DO/SQLite dodatkowo wykonał HKDF/AES-GCM i round trip syntetycznej koperty. Syntax 76 MJS. [Kontrakt i granice](REKORD_AVATARA_I_ODZYSKIWANIE.md), [dowody/SHA](evidence/avatar-records-local-tests.json).

Bez aktywacji HTTP/runtime/usługi/schema/ról/sekretów, realnego CKAsset/Free/A-B i zmian Swift/UI/Core/projektu/dependencies. Nie powtarzano iOS/SDK lub audytu niezmienionego lockfile. Rekord ma pending moderation, bez CAS profilu. Nadal potrzebne bounded intake, odczyt/cache, porzucenie nieznanej wersji, alarm retencji, odbiór chmury i pełna integracja produktu.


## CK-04e.3e — zgoda, decyzja moderacji i CAS zdjęcia

353/353 Node22.23.5 i Node24.22.1 (24 nowe), syntax 80 MJS. Rzeczywisty lokalny normalizator/SQLite/crypto/checkpoint, modele Apple/tożsamości/operatora. Zgoda na konkretną wersję przed kodekiem, source hash i trwały serwerowy opis plików przed uploadem; recovery tylko po requestID. Oddzielny proponowany singleton CloudKit EchoesAvatarProfileV1 chroni zdjęcie przed edycją nazwy. CAS generacji, latest intent/CloudKit tag, pending-review, role hook i moderation revision blokują stare ACK oraz approve→reject→approve. Clear ukrywa od razu i zachowuje ukrycie po utracie odpowiedzi.

Testy obejmują zgodę/idempotencję/obce konto, trzy wybory w stałym oknie i 1000 wpisów bez blokowania clear, awarie SQL/sync, mutable source, finalizery, oba porządki clear/RPC, utratę ACK, erasure i rollback. Lokalne workerd/DO/SQLite wykonało nowe schema/transaction/sync/select/clear/erase bez outbound; negatywna kopia bez guard CAS clear oblewa test. Pierwszy błąd wygasłej modelowej sesji poprawiono świeżym logowaniem. [Kontrakt i otwarte bramki](ZGODA_MODERACJA_I_PROFIL_ZDJECIA.md), [dowody/SHA](evidence/avatar-publication-local-tests.json).

Bez nowego HTTP/aktywacji/usług/schema/ról/sekretów, realnego CloudKit/Free/A-B, zmian Swift/UI/Core/projektu/zależności i powtarzania ich testów. To mechanika decyzji; panel/operator, rzeczywisty przegląd zdjęć i zgłoszenia pozostają otwarte. Chroniony odczyt/cache, intake, iOS/journal, retencja i rzeczywisty odbiór nadal w pełnym zakresie migracji.


## CK-04e.3f — chroniony JPEG i rewalidacja cache

380/380 Node22.23.5 i Node24.22.1 (27 nowych: 26 reader + 1 rzeczywistego workerd), syntax 85 MJS. Odczyt wiąże bieżącą zgodę/wersję/moderację z potwierdzonym wskazaniem i assetami; dla obcego odbiorcy aktywna obecność, expiry, obie blokady i 3 km od zadeklarowanej pozycji. Kontrole po sieci i ostatnim checkpoint/finalizerze. Nowy GET z zamkniętym hostem i bez sekretów, bounded body/SHA/wymiary, 4 aktywne bilety/do 8 s i jednorazowe Response. knownSHA256 daje świeżo autoryzowane 204 bez GET; nie stanowi zapamiętanego uprawnienia.

Workerd/SQLite/auth/policy/rejestr/podpisy rzeczywiście obsłużyły binarny 200, cache 204 i odmowę po bloku; Apple/tożsamości są modelowane. Wykryto brak Request.credentials w runtime, skorygowano tylko fixture i usunięto diagnostykę; świeże nagłówki nadal sprawdzane. Negatywna kopia bez guard 3 km oblewa test. Odczyt nie odnawia generacji mutacji autora po zmianie jego sesji. [Kontrakt](CHRONIONY_ODCZYT_AVATAROW.md), [dowody/SHA](evidence/avatar-read-local-tests.json).

Bez nowego HTTP/runtime aktywacji, usług/schema/ról/sekretów, realnego providera/Free/A-B, zmian Swift/UI/Core/projektu/zależności lub powtarzania ich testów. Natywny cache/transport, intake/admission/UI/operator/zgłoszenia/retencja i realny odbiór nadal wymagane.


## CK-04e.3g — natywny odbiór chronionych zdjęć

246/246 testów Swift (24 nowe: 16 kontraktu/klienta i 8 rzeczywistego URLSession), strict swift-format 3 plików oraz Debug Simulator/Release iOS. Osobny transport weryfikuje manifest/nagłówki przed buforowaniem, dokładne rozmiary i SHA, wariant/owner/version, świeże puste 204 i błędy JSON do 32768 bajtów. Brak przekierowań/cache/cookies/credential storage, cztery aktywne odczyty, zwalnianie slotów, kontrola anulowania i domyślnego wyłączenia. Dane eksportu rzeczywistego readera/policy/rejestru/checkpoint i Wasm przechodzą przez klienta/URLSession/ImageIO; konta i Apple są modelowane. Usunięcie porównania URL w kontroli negatywnej oblało test; przywrócono dokładny source przed pełnym przebiegiem.

Podczas walidacji poprawiono inicjalizację throws i zagnieżdżone makro w testach; rozdzielono odrzucenie nieprawidłowego GatewaySecret od odrzucenia kształtu tokenu przez klienta. Odmówiony redirect w URLProtocol może zakończyć się błędem Foundation przed dostarczeniem 307; test wymaga błędu i dokładnie jednego żądania na właściwy host. Nie uznaje tego za działający endpoint HTTPS. [Kontrakt i granice](NATYWNY_TRANSPORT_AVATAROW.md), [dowody/SHA](evidence/avatar-native-http-local-tests.json).

Bez UI i nowego runtime/HTTP po stronie serwera; brak cache/sterownika odbiorcy, zmian usług/schema/ról/sekretów, opłat, operacji SDK/Production/Firebase lub odbioru prawdziwego providera/Free/A-B. Ordinary entry nadal Firebase, flagi i aktywacje niezmienione. Źródła gateway/Core, zależności i projekt identyczne; ich pełnych testów nie powtarzano. Zachowano zastaną zmianę project.pbxproj. Dalej CK-04e.3h cache per odbiorca i usuwanie, potem pozostały pełny plan.


## CK-04e.3h.1 — trwały cache per odbiorca i exact erasure

267 zdefiniowanych testów pakietu: 266 zaliczonych i 1 jawnie pominięty wymagający fizycznego iOS; te same wyniki na macOS i iPhone 17 Pro Simulator/iOS 26.1. Nowe 20 testów lokalnych oraz jedna bramka urządzenia. Debug/Release i strict swift-format 3 plików poprawne. Cache izoluje konto Echoes/iCloud, native binding i origin, wiąże owner/version/wariant, sprawdza bounded envelope/SHA/ImageIO, stosuje 64 wpisy/8 MiB i storedAt do 24 h bez odnowienia przy hit. LRU, limity 8 private/2 community scope, bounded skany i cleanup własnych temp. Atomowy O_EXCL/fsync/rename, 0700/0600, backup exclusion i iOS complete przed treścią; na fizycznym iOS wymagany odczyt potwierdzenia atrybutu przed zapisem.

Runtime posiada jedną instancję i dodaje jej fence/erase przed localDataDeleted i private ACK. Test z rzeczywistym GatewayDeletionController i lokalnym cache, przy modelowanym API/CloudKit, zatrzymuje ACK po nieznanym pliku, odcina późny zapis, zachowuje inne konto i kończy scoped retry bez powtórzenia private cleanera. Negatywna kontrola bez erase-fence oblała test; źródło przywrócono.

Pierwsza kompilacja wymagała jawnego Int dla UTIME_OMIT. Pierwsza próba symulatora oblała nową kontrolę ochrony: dla syntetycznego pliku FileManager zwraca nil. Diagnostyka potwierdziła wyłącznie tę wartość, bez ścieżek/bajtów; została usunięta. Próba wąskiego filtra wybrała zero testów i nie jest zaliczeniem. Pełny przebieg potwierdził ograniczenie tego symulatora. Test fizycznej ochrony został osobną jawną bramką; brak realnego telefonu, blokady ekranu lub dowodu kryptografii. Nie obniżono wymagania na urządzeniu: cache odmawia zapisu bez potwierdzonego complete. Końcowe 266+1 na obu platformach i Debug/Release przeszły po fsync erasure i finalnym kodzie. [Kontrakt](NATYWNY_CACHE_AVATAROW.md), [dowody/SHA](evidence/avatar-native-cache-local-tests.json).

Czas 24 h dotyczy kwalifikowania przy odczycie; lazy cleanup nie jest gwarancją fizycznego usunięcia po czasie, w backupie lub snapshotach. Cache nie dowodzi uprawnień ani usunięcia metadanych — bajty mają pochodzić z normalizującego gateway. Natywny sterownik/świeża rewalidacja/native i visibility fences oraz UI są w następnym CK-04e.3h.2. Brak nowych usług/kluczy/ról/sekretów/opłat, operacji SDK/Production/Firebase, zmian projektu/zależności/gateway/Core lub odbioru realnego providera/Free/A-B. Zwykła ścieżka nadal Firebase, aktywacje wyłączone. Zachowano zastany project.pbxproj; pełny cel pozostaje aktywny.


## CK-04e.3h.2 — natywny sterownik i świeża autoryzacja zdjęć

304 zdefiniowane testy pakietu: 303 zaliczone i 1 jawny skip sprzętowego FileProtection; identycznie na macOS i iPhone 17 Pro Simulator/iOS 26.1. 37 nowych testów, strict swift-format 4 plików i Debug/Release poprawne. GatewayAvatarClient łączy snapshot native/private iCloud/cache lease, świeży token/HTTP przy każdym load i rzeczywisty ImageIO. Obowiązkowy isVisible bez permissive default, origin/Development guard, epoki wersji/widoczności, kontrola po każdym await i przy renderze. Pełny manifest 204 musi odpowiadać zweryfikowanemu cache; błąd lub odmowa nie dają offline fallback. Utrata lease odcina kontekst, późne 401 nie odrzuca nowego konta, nieznane błędy są zamykane bez szczegółów zależności. GatewaySignInHost spełnia nowy protokół istniejącymi metodami, bez nowych żądań lub profilu.

Wynik jest opaque uchwytem bez pikseli/sekretów. 4 pending także po cancel do rzeczywistego zwrotu, jeden niedokończony connect, 32 obrazy i 8 MiB zarządzanych rastrów. Do 30 s od początku request, bez odnawiania czasu przy późnym RPC. Rzeczywisty test zegara/Observation na obu platformach potwierdził automatyczne usunięcie i reschedule drugiego obrazu bez kolejnego render/refresh. Testy modeli zatrzymują cache/token/HTTP/decode/store, ignorują cancel, zmieniają native/cloud/revision/widoczność/wersję/ABA i zachowują nowe B po późnym wyniku A. Fixture rzeczywistego serwera przechodzi przez GatewayAvatarHTTPClient, trwały cache i NativeGatewayAvatarDecoder/ImageIO.

Kontrola negatywna bez porównania private iCloud scope oblała test: niepożądany uchwyt i zapis cache. Przywrócono source; końcowy przegląd dodał sanitizację nieznanych błędów i test obu granic. Pełne przebiegi i Debug/Release powtórzono po tej zmianie; 303+1 na obu platformach. Poprawiono też odcięcie wcześniejszych uchwytów przed odmową backpressure i guard niepoprawnego zegara. [Kontrakt](NATYWNY_STEROWNIK_AVATAROW.md), [dowody/SHA](evidence/avatar-native-client-local-tests.json).

To sterownik przed serwerowym HTTP/admission, referencjami w profilu/feed i UI — Runtime jeszcze go nie tworzy. Host musi używać jednej współdzielonej instancji, odcinać lifecycle/domain/obszar/bloki/wersje i przechowywać uchwyty zamiast kopii CGImage. 8 MiB nie jest pomiarem RSS, 30 s nie odwołuje skopiowanych bajtów i nie uruchamia automatycznie kolejnego RPC. UI/limity Free/realny odbiór pozostają wymagane. Bez zmian gateway/Core/projektu/zależności/CI, ich pełnych testów lub UI nie powtarzano. Bez nowych usług/schema/ról/kluczy/sekretów/opłat, instalacji telefonu/SDK/Production/Firebase lub odbioru ról/SIWA/hosted Free/A-B; ordinary entry nadal Firebase i aktywacje wyłączone. Zastany project.pbxproj zachowany. Pełny cel aktywny; dalej CK-04e.3i i pozostały plan.


## CK-04e.3i.1 — serwerowy HTTP/admission zdjęć

406/406 Node22.23.5 i Node24.22.1, 26 nowe (25 HTTP/admission + 1 pełnego lokalnego workerd); syntax90MJS i cztery JSON poprawne. Odrębna wyłączona flaga/hosty, konkretny singleton Reader w Runtime, zamknięty POST2048B i 200 JPEG/fresh204. GatewayLimits global/IP heavy oraz nowe trwałe konto12/min/image4/min przed jakimkolwiek checkpoint/provider, bez klientowego budget/account ID. Cztery aktywne żądania w Authority, wspólny total12s, body3s i synchroniczny Response finalizer po ostatnim await. Wspólny parser ogranicza128 niepustych chunks/długość/UTF8/anulowanie; zero-chunk flood nie odsuwa timera.

Edge zachowuje stały prywatny obiekt i platformowy HMAC, odrzuca spoofed/browser context i nie kopiuje sekretów. Dla zdjęcia osobna bounded kopia/SHA do256000/32000B, cztery sloty, total15s i TypedArray dający prawidłowy Content-Length w Workers. Biała lista nagłówków, prywatne no-store204 bez body, brak JSON masquerading/zakresu/kompresji/przekierowania i kontrola flag po kopiowaniu. enable_request_signal wpisany jawnie, rozpoznany lokalnie; nie włączono funkcji ani usługi.

Rzeczywiste lokalne workerd/DO/SQLite/runtime/authority/edge/HMAC i niezależnie weryfikowane ECDSA dały poprawny HTTP Content-Length/SHA200, cache204 bez GET i po bloku404 bez assetGET. Apple/pliki/konta/platformowe CF metadata są modelowane, dwa klucze efemeryczne/niezarejestrowane; outbound IPv4/IPv6/Unix zabroniony. Kontrola negatywna bez account quota oblała test. Najpierw28 starych HTTP przeszło; pierwszy quota test poprawiono z oczekiwania200 na204 przy cache. Rozszerzony test anulowania wykrył brak cancel nieodczytanego body i pozostawiony parser po total timeout — parser otrzymał wspólny sygnał i cleanup wejścia. Końcowy przegląd wykrył ryzyko abort strumienia błędu po cleanup. Edge kopiuje także zamknięty JSON błędu (32768B/128 części, ta sama pula czterech slotów); test 401 odczytuje body po zamknięciu sygnału. Kontrola negatywna bez kopii oblewa ten test. Końcowe pełne zestawy 406/406 na obu Node po tej poprawce i fladze signal. [Kontrakt i granice](HTTP_AVATAROW_GATEWAY.md), [dowody/SHA](evidence/avatar-http-route-local-tests.json).

Nie zmieniono Swift/Core/UI/projektu/deps/CI lub kontraktu natywnych nagłówków; ich buildów/UI/SDK i niezmienionego audytu nie powtarzano. Odbiór lokalny nie zalicza hosted Cloudflare CPU/transferu/cold-start/disconnect, prawdziwych hostów/schema/ról/SIWA ani zwykłego iCloud A/B. Authority sprawdza politykę przed emisją; edge nie odwołuje już dostarczonych bajtów. Limity są konserwatywne dla kontrolowanego Development, nie dowodzą darmowej skali. Brak nowych uprawnień/usług/kluczy/sekretów/opłat, zdalnej aktywacji/deploy lub operacji Production/Firebase/TestFlight. Zastany project.pbxproj zachowany, flagi0. Dalej CK-04e.3i.2 wersje zdjęć w profilu/feed i cała reszta celu.


## CK-04e.3i.2a — serwerowe wskazania wersji zdjęć (17 listopada 2026)

427/427 na Node22.23.5 i Node24.22.1, 21 nowych; syntax92MJS/4JSON poprawne. CommunityAvatarReferences w konkretnym Runtime dzieli AvatarPolicyState z Readerem. Profil/mapa/historia zawierają opcjonalne avatarVersionID: nadal wybrana zatwierdzona wersja albo null. Nigdy URL/receipt/hash/manifest/stan moderatora lub plik. Repozytorium weryfikuje rzeczywisty rekord wskazania. Do100 autorów, partie25 i ten sam limit40 wywołań lease; mapa używa istniejących zweryfikowanych obecności. Bez pobierania CKAsset/pliku lub podnoszenia budżetów.

Końcowy synchroniczny guard po checkpoint ponownie sprawdza publikację/tag/wersję/generację i peer presence/obszar/bloki. Wycofanie moderacji/clear/zamiana, stop/expiry, oba kierunki blokady, zawieszenie i przesunięcie autora poza obszar odcinają stare wskazanie. Własny profil nie wymaga GPS. Wiadomość może przetrwać obecność autora, wtedy avatarVersionID=null. Stary finalizer nie dodaje nowszej wersji. Flaga/hosty/termin aktywacji są wspólne z Readerem; wyłączone metadane nie wykonują pointer lookup.

Rzeczywiste lokalne SQLite/konkretne koordynatory/repozytorium/Runtime sprawdzono z modelami Apple i kont. Test partii pokrywa100 autorów i brak dodatkowego lookup obecności mapy. Kontrola negatywna bez assertReadPublication oblała test po wycofaniu zatwierdzenia; kod przywrócono przed pełnymi przebiegami. Pierwsze fixture poprawiono do rzeczywistych nazw metod; test presence expiry rozdzielono od session expiry (świeża sesja przed wygaśnięciem obecności + oddzielna odmowa całej odpowiedzi). Kontroli sesji nie rozluźniono. Istniejąca regresja workerd przechodzi; osobny rzeczywisty hosted/Apple odbiór tego wzbogacania nie jest zaliczony. [Kontrakt](WERSJE_AVATAROW_W_DANYCH_SPOLECZNOSCIOWYCH.md), [dowody/SHA](evidence/avatar-reference-local-tests.json).

Zmiana dotyczy serwera; natywny parser jeszcze nie zachowuje nowego pola, UI pozostaje do integracji. Swift/Core/projekt/deps/CI/config identyczne; ich buildów/UI/SDK i niezmienionego audytu zależności nie powtarzano. Bez nowych uprawnień/schema/kluczy/sekretów/usług/opłat, aktywacji/deploy lub operacji Production/Firebase/TestFlight. Zastany project.pbxproj zachowany. Dalej CK-04e.3i.2b natywne modele/parser i przekazanie wersji do sterownika, następnie pełna reszta planu; cel aktywny.


## CK-04e.3i.2b — natywne wersje zdjęć (17 listopada 2026)

Core26/26 oraz CloudKit308 zaliczonych+1 jawny skip sprzętowy na Macu i iOS26.1/iPhone17Pro Simulator; raporty xcresult zgodne. 9 nowych funkcji (4 Core, 5 CloudKit; jedna z trzema przypadkami faz), strict swift-format7 plików i pełne kompilacje Debug Simulator/Release iOS poprawne. Parser zamyka nested profile/users/messages do znanych pól i zachowuje tylko avatarVersionID jako kanoniczny UUID/null/brak. URL/receipt, obcy owner/manifest, błędny typ/ID lub niewłaściwy poziom pola odrzucają całą odpowiedź. Opcjonalne modele Core zachowują starszy JSON i legacy ID bez zdjęcia; Equatable, CommunitySession i timeline przenoszą, zmieniają i usuwają wersję po null.

Typowane rozszerzenia tworzą AvatarReference dla właściwego właściciela, bez grant/URL. Nowy exporter wykonał konkretny Runtime/HTTP/SQLite/politykę z modelami Apple, wygenerował dziewięć odpowiedzi published/cleared/disabled i thumbnail1233B200/fresh204 tej samej publikacji, bez tokenów/receipts/URL. Natywny most sprawdził parser -> referencję mapy -> GatewayAvatarClient/HTTP -> trwały cache -> rzeczywisty ImageIO; drugi odczyt ponownie autoryzuje cache i odcina pierwszy uchwyt, zastosowanie clear odcina drugi i nie wykonuje kolejnego transferu. Transport i natywne konto są modelami; nie jest to realny SIWA lub hostowany gateway. Kontrola negatywna pominięcia wersji mapy oblała published z trzema problemami, kod przywrócono przed pełną regresją. [Kontrakt i granice](NATYWNE_WSKAZANIA_AVATAROW.md), [dowody/SHA](evidence/avatar-native-reference-local-tests.json).

Pierwsze buildy całej aplikacji zatrzymał brak firebase-ios-sdk w starym /tmp cache. Wykorzystano izolowaną kopię dostępnego cache; dwie różnice HEAD wobec lockfile dopasowano do przypiętych rewizji, brakujący GoogleUtilities pobrano wyłącznie w dokładnej rewizji z Package.resolved. SwiftPM potrzebował jej również w swoim izolowanym magazynie bare. Ostateczna rekonstrukcja grafu i oba buildy przeszły. Nie zmieniono lockfile, projektu, zależności lub oryginalnego cache Xcode; nie aktualizowano wersji. W zbudowanych pakietach brak zasobów aktywacji/probe i konfiguracji gateway.

Gateway funkcjonalny/config/CI niezmienione; nie powtarzano całych427 testów gateway lub niezmienionego audytu — nowy exporter wykonano offline i sprawdzono składnię na obu Node. UI/SDK na telefonie nie powtarzano. Sprzętowy FileProtection, realne schema/role/hosty/SIWA/service identity/Free i dwa zwykłe konta pozostają otwarte. Runtime aplikacji nadal nie tworzy klienta zdjęć/rendererów, ordinary entry nadal używa Firebase, aktywacje wyłączone. Bez nowych usług/uprawnień/kluczy/sekretów/opłat, deploy/Production/Firebase/TestFlight. Zastany project.pbxproj zachowany. Dalej CK-04e.3i.3 foreground host/predicate/lifecycle/renderer, potem uploader/journal/UI/operator/zgłoszenia/retencja i pełna reszta planu; cel aktywny.


## CK-04e.3i.3a — współdzielony host i granice prezentacji zdjęć (17 listopada 2026)

Core28/28 i CloudKit319 zaliczonych+1 jawny skip sprzętowy na Macu oraz iPhone17Pro Simulator/iOS26.1; xcresult zgodny. 13 nowych funkcji (2 Core, 11 hosta), strict swift-format8 plików, pełne Debug Simulator/Release iOS poprawne. GatewayDevelopmentRuntime tworzy jeden GatewayCommunityAvatarHost nad dotychczasowym klientem/cache i przekazuje osobny binding do AppServices. invalidateNativePresentation odcina go synchronicznie; stary binding nie zamyka nowego konta. Legacy/preview AppServices domyślnie ma nil, brak nowych aktywacji.

Core ma jednego słabego wyłącznego obserwatora prezentacji; zmiany stanu powiadamiają synchronicznie przed kolejnym await. BlockingUserIDs obejmuje próbę block/unblock przed adapterem, a cleanup jest ograniczony epoką konta. Host sprawdza bieżący rekord rodzica, foreground/native/private scope/GPS, wygasanie/bloki, mapę/3 km lub konkretną wiadomość otwartego czatu. Null lub nowsza wersja mapy odcina stare wskazania wiadomości. Gettery sprawdzają czas także bez tick/sieci. Natywne eventy tożsamości nadal muszą zamykać binding na granicy clearDomainState.

Do320 odbiorców, cztery niezakończone transfery i jeden connect także po rebind; anulowane nie ignorują globalnego licznika. Równocześni odbiorcy współdzielą tylko oczekującą świeżą odpowiedź; nowy po zakończeniu ponownie autoryzuje i zastępuje wspólny uchwyt. Warianty są rozdzielone, brak IO zdjęć przed rejestracją odbiorcy. Lokalne12/min i4image/min na Runtime nie zastępują trwałych limitów serwera i nie dowodzą darmowej skali. Brak automatycznej pętli retry/odnawiania co30s. Błąd connect kończy loading, a jawny retry go wznawia.

Testy używają rzeczywistego CoreSession/klienta/cache/filesystem/ImageIO z modelami tożsamości/API. Obejmują pending block przed ACK, awarię/ABA/zmianę konta przy4 zatrzymanych odczytach, stare invalidation/release, null/warianty/expiry/czat, limity i320 odbiorców. Kontrola negatywna pomijająca pending block oblała jeden test z2 problemami i ujawniła CGImage przed ACK; kod przywrócono. Test błędu connect najpierw oblał się z1 problemem z powodu wiszącego loading; poprawiono guard, focused11 i końcowe pełne zestawy przechodzą. Rejestrację/zwalnianie zmieniono na przyrostowe po syntetycznym focused10 około5,3s, po zmianie około0,18s; nie jest to pomiar płynności UI. [Kontrakt](HOST_ZDJEC_SPOLECZNOSCIOWYCH.md), [dowody/SHA](evidence/avatar-host-local-tests.json).

Renderer i rejestrowanie lease w widokach pozostają kolejnym CK-04e.3i.3b; ten etap nie pokazuje jeszcze zdjęć w UI. Nie powtarzano niezmienionych UI testów ani SDK/instalacji telefonu. Gateway/config/projekt/lockfile/deps/CI identyczne, ich pełnych testów/audytu nie powtarzano. Fizyczny FileProtection, realne schema/role/hosty/SIWA/service identity/Free i dwa zwykłe konta nadal otwarte. Bez nowych usług/uprawnień/kluczy/sekretów/opłat, deploy/Production/Firebase/TestFlight. Zastany project.pbxproj zachowany; ordinary entry nadal Firebase, cel aktywny.


## CK-04e.3i.3b — renderer i UI zdjęć

Postęp CK-04e.3i.3b (17 listopada 2026): wspólny renderer rejestruje opaque lease na mapie, w profilu i wiadomości; nie przechowuje pikseli w stanie. Klucz obejmuje referencję/powierzchnię/binding/scene i obserwowalną gotowość. Inicjał po odmowie/wygaśnięciu, jawny retry profilu, zwalnianie na lifecycle i duży przewijany panel. 23/23 końcowych UI (7 nowych), CloudKit320 zaliczonych+1 sprzętowy skip na Macu/Simulatorze, nowy test gotowości i strict format11. Release oraz Debug z końcowego UI poprawne; negatywna kontrola bez lease oblewa 3 asercje renderowania. Zrzuty rzeczywistego symulatora używają syntetycznych JPEG/tożsamości; brak realnego gateway/SIWA/iCloud A-B. Bez nowych aktywacji/usług/opłat lub SDK telefonu. Ordinary entry nadal Firebase. Dalej CK-04e.3j: serwerowy ograniczony intake, natywny upload/journal/własne zdjęcie, operator/zgłoszenia/retencja i pełny rzeczywisty odbiór. [Renderer i granice](RENDERER_AVATAROW_IOS.md), [dowody](evidence/avatar-ui-local-tests.json).

Test wygaśnięcia UI pracuje z odświeżaną sesją podglądu; nie izoluje samego timera SwiftUI. Pakietowy test automatycznego expiry/Observation bez refresh nadal przechodzi na obu platformach. Zmiana testowego konta i dwa kolory JPEG nie zastępują realnego iCloud A/B. Wcześniejszy test SDK z 16 listopada nie był powtarzany.
