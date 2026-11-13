# Weryfikacja migracji CloudKit

Stan: 13 listopada 2026. **Migracja nie jest odebrana i aplikacja nie została przełączona na CloudKit.**

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

Po konkretnej zgodzie właściciela zapisano w Apple klucz publiczny „Echoes Development gateway probe 2026-11-12” w `iCloud.mpvEcho.Echo`, wyłącznie Development. Portal potwierdził „Server-to-server key created successfully”. Klucz prywatny pozostaje lokalnie poza Git, w pliku z uprawnieniami 0600 i katalogu 0700; nie przekazano go Cloudflare. Fingerprint SHA-256 publicznego SPKI: `8c42a2a2bcfc81ebff8ef0838923f84654ccf8dc8401777d9c26f51766e68b11`. Sam identyfikator klucza nie jest potrzebny w repozytorium.

[Pierwszy raport S2S](evidence/cloudkit-s2s-probe-development-initial.json): zapis niepotwierdzony, `NOT_FOUND`, odczyt niewykonany, nieobecność testowego UUID potwierdzona podczas sprzątania. Raport nie jest pozytywnym odbiorem S2S. Odczyt listy schematu potwierdził brak typu `EchoesGatewayProbeV1`; istnieją wyłącznie `EchoesAccessProbeV1` i `Users`. Nie poszerzano odczytu o dane użytkowników. Zgłoszenie zapisu do nieistniejącego typu nie utworzyło automatycznie definicji w tej ścieżce.

Automatyczna kontrola odrzuciła próbę utworzenia trwałego typu Development jako nieobjętą wcześniejszą zgodą na klucz/rekord. Nie obchodzono blokady. Właściciel został poproszony o osobną zgodę na nowy typ, pola nonce String / schemaVersion Int64, wyłącznie serwerowy dostęp i ponowienie próby. Do czasu odpowiedzi schemat nie jest zmieniony; formularz jest jedynie przygotowany.

## CK-01f — typ, ograniczone role i udany test S2S — 13 listopada 2026

Po odrębnej zgodzie właściciela utworzono wyłącznie w Development `EchoesGatewayProbeV1`, pola `nonce: String` i `schemaVersion: Int64`. Nie dodawano indeksów do tej próby po nazwie rekordu, nie promowano schematu i nie zmieniano definicji wcześniejszych typów.

Dla nowego typu wyłączono wszystkie prawa standardowych ról: `_world`, `_icloud`, `_creator`. Odświeżone widoki po zapisie potwierdziły brak tego typu w przypisaniach tych ról. [Udokumentowana konfiguracja](evidence/cloudkit-gateway-probe-schema-development.json) jest zapisem obserwacji, nie importowalnym schematem Apple ani automatycznym audytem całego kontenera.

Próba po samym odebraniu praw klientom zwróciła **ACCESS_DENIED również dla S2S**, z potwierdzoną nieobecnością losowego rekordu: [raport odmowy](evidence/cloudkit-s2s-probe-development-denied.json). Skorygowano wcześniejsze założenie o automatycznym omijaniu ról. S2S dziedziczy prawa twórcy klucza, co potwierdza [przykład Apple](https://developer.apple.com/go/?id=cloudkit-catalog).

Dodano rolę `EchoesGatewayProbeService`, prawa Create/Read/Write wyłącznie dla `EchoesGatewayProbeV1`. Z bieżącej tożsamości klucza (`users/caller`) odczytano tylko identyfikator potrzebny do przypisania. W konsoli pobrano wyłącznie odpowiadający mu rekord Users i przypisano tę rolę; nie zmieniono pól profilu, definicji Users ani ról innych użytkowników. W repozytorium znajduje się tylko hash identyfikatora, bez surowego userRecordName i danych osobowych.

**Końcowy wynik: zapis, odczyt poprawnego nonce i schemaVersion oraz usunięcie — wszystkie poprawne.** [Raport rzeczywisty](evidence/cloudkit-s2s-probe-development.json): przebieg `4899adac-afe0-45a4-92f3-d3b426733f7c`, `2026-11-13T08:58:09.014Z`. Rekord został usunięty. Nie odczytywano mapy, czatu, GPS, muzyki ani prywatnego profilu.

Przypisanie roli dotyczy konta, nie wyłącznie pliku klucza. Urządzenie zalogowane jako ten operator również ma jego prawa. Przed produkcją wymagana jest oddzielna tożsamość serwisowa i test natywnych, nieuprzywilejowanych kont A/B; nie deklarujemy jeszcze ich odbioru. Wcześniejszych domyślnych ról innych typów nie zmieniano.

Klucz zachowano w trwałym lokalnym katalogu poza wszystkimi worktree Git (katalog 0700, pliki 0600), aby nie polegać wyłącznie na plikach tymczasowych. Nie przekazano go Cloudflare i nie uruchomiono płatności. Test lokalny nie jest jeszcze testem pośrednika sieciowego ani limitem CPU Workers.

## CK-01g — lokalny prototyp Workers

Przeszło 25 testów Node 22 (12 wcześniejszych, kontekst, 6 HTTP i 6 rezerwacji SQLite). Dodatkowo sprawdzono składnię MJS. Są to testy lokalne SQLite/Node, nie runtime Cloudflare. Prototyp jest wyłączony, endpoint nie jest wdrożony i sekret nie trafił do Cloudflare. Npm/curl nie połączyły się poprawnie z oficjalnym registry.npmjs.org; instalacja Miniflare nie nastąpiła. [Zakres i dalsze próby](WORKERS_DIAGNOSTYKA.md).

## CK-02c — porównanie konta urządzenia z tożsamością serwera

13 listopada 2026 skompilowano i podpisano Debug, zaktualizowano zatwierdzoną aplikację na ponownie podłączonym iPhonie 15 Pro bez odinstalowania/danych i uruchomiono osobną kontrolę konta. Wymagała odblokowania ekranu przez właściciela. [Raport rzeczywisty](evidence/cloudkit-identity-check-device.json) potwierdza dostępne konto zgodne z kontem twórcy klucza. Nie odczytano profilu ani rekordów aplikacji, GPS lub muzyki; wynik zawiera wyłącznie UUID/czas i booleany.

Właściciel potwierdził, że obecnie dysponuje tylko tym kontem. Konta operatora nie używamy jako dowodu odmowy dla zwykłego użytkownika. Natywna próba A/B pozostaje otwarta; nie wylogowywano właściciela i nie zmieniano Apple ID. Odbiór przed publikacją nadal wymaga osobnego, nieuprzywilejowanego konta testowego.

## CK-01h — stan Cloudflare przed publikacją prototypu

Utworzono pustą usługę echoes-development-probe z domyślną odpowiedzią Hello World. Plan Free / Current plan / $0 potwierdzono ponownie w panelu 13 listopada. Brak sekretów, bindings i dostępu do CloudKit. [Zapis obserwacji](evidence/cloudflare-development-worker-bootstrap.json). Automatyczna kontrola zatrzymała dodanie pierwszego pliku do zdalnego edytora jako niezatwierdzoną modyfikację aktywnej usługi. Kod prototypu Echoes nadal nie jest wdrożony; oczekuje konkretna zgoda na zdalny kod, konfigurację próby i nowego odbiorcę klucza. Nie zmieniono CloudKit Production ani nie uruchomiono opłat.
