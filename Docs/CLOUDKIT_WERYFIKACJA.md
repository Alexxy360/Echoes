# Weryfikacja migracji CloudKit

Stan: 12 listopada 2026. **Migracja nie jest odebrana i aplikacja nie została przełączona na CloudKit.**

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
| Dwa konta A/B w Development | Niewykonana | B nie odczyta prywatnych danych A ani nie zmieni cudzych rekordów; opisać faktyczny zakres publicznego odczytu. |
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
