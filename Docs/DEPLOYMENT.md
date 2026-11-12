# Wdrożenie backendu Echoes

Backend używa Node.js 22, Firebase Authentication, Firestore Standard i callable Cloud Functions 2. generacji w `europe-west1`. Klient i backend są wdrażane razem: stary klient nie działa z nowymi regułami i modelem danych.

## Warunki przed wdrożeniem produkcyjnym

1. Właściciel projektu aktywuje plan **Blaze**. Uruchomienie rozliczeń wymaga jego decyzji i wykonania kroków płatniczych; samo przygotowanie kodu niczego nie aktywuje. Funkcje i TTL mogą generować opłaty za użycie.
2. W Firebase Authentication włączyć dostawcę **Anonymous**. Aplikacja tworzy sesję bez ekranu hasła.
3. Zarejestrować aplikację iOS w App Check z App Attest i DeviceCheck, jeśli ma służyć jako fallback. Produkcyjne callable functions wymagają poprawnego App Check w swoim kodzie. Debug korzysta z providera debug; token jest prywatny i powinien być rejestrowany wyłącznie w środowisku developerskim.
4. Przed publikacją ustawić publiczny adres wsparcia w `backend/.env.<PROJECT_ID>` jako `SUPPORT_URL=https://...` albo `mailto:...`. Właściciel zdecydował, że poda go później. Nie używać fikcyjnego adresu.
5. Ustalić osobę i proces regularnego przeglądania `communityReports`. Sam filtr tekstowy jest podstawową ochroną, a nie kompletną moderacją.
6. Sprawdzić zgodność `PROJECT_ID`, Bundle ID i Apple Team z lokalnym `GoogleService-Info.plist`. Plik pozostaje ignorowany przez Git.

## Weryfikacja lokalna

```sh
npm ci
npm --prefix backend ci
npm run test:backend
npm run test:integration
swift test --package-path EchoesCore
```

Testy integracyjne używają wyłącznie projektu `demo-echoes` i emulatorów na `127.0.0.1`. Emulator nie wykonuje fizycznego kasowania TTL, więc testy sprawdzają niezależnie wygaszanie w logice backendu i klienta.

Do uruchomienia aplikacji przeciw emulatorom ustawić w schemacie Xcode, wyłącznie w Debug:

- `ECHOES_USE_EMULATORS=1`
- opcjonalnie `ECHOES_EMULATOR_HOST`, domyślnie `127.0.0.1` dla symulatora.

Projekt SDK w tym trybie jest automatycznie zastępowany przez `demo-echoes`. Wydanie Release ignoruje te przełączniki. `ECHOES_DEMO_MODE=1` uruchamia osobny podgląd z fikcyjnymi danymi, bez Firebase i bez GPS; ten podgląd nie zastępuje testu integracji.

## Wdrożenie po aktywacji usług

Zalogować Firebase CLI na konto właściciela i jawnie wskazywać docelowy projekt. Nie przechowywać tokenów CLI ani kluczy administracyjnych w repozytorium.

```sh
npm --prefix backend run build
npx firebase deploy --project PROJECT_ID --only firestore:indexes,functions:echoes
```

Poczekać na gotowość indeksu `communityMessages` i potwierdzić aktywność TTL dla:

- `communityPresence.expiresAt`: profil wygasa po 10 minutach;
- `communityMessages.expiresAt`: wiadomość wygasa po 2 godzinach;
- `communityReports.expiresAt`: zgłoszenie wygasa po 30 dniach;
- `communityAccounts.expiresAt`: dotyczy tylko pozostałego po usunięciu konta minimalnego znacznika blokującego (24 godziny). Zwykłe konto nie ma tego pola.

Konfiguracja TTL znajduje się w `firestore.indexes.json`. W konsoli należy potwierdzić wykonanie operacji; samo posiadanie pliku nie dowodzi aktywacji polityki. TTL usuwa dokumenty asynchronicznie. Backend i klient odrzucają wygasłe dane niezależnie od postępu kasowania.

Następnie wdrożyć reguły:

```sh
npx firebase deploy --project PROJECT_ID --only firestore:rules
```

Reguły blokują cały bezpośredni dostęp SDK klienta do Firestore. Uprawnione funkcje korzystają z Admin SDK, walidują tożsamość, App Check, treść i zakres odpowiedzi. Sprawdzić po wdrożeniu każde z tych ograniczeń oraz minimalne uprawnienia konta usługi funkcji.

Na końcu wykonać próbę dwóch urządzeń: sesja, prywatny start, świadoma widoczność, zmiana utworu bez ruchu, wysłanie i stronicowanie czatu, blokada, zgłoszenie, tło, powrót i usunięcie własnych danych. Dopiero potem dystrybuować nowy klient.

## Dane starej wersji

Stare kolekcje `users` i `messages` nie są odczytywane przez nową aplikację. Nie zostały usunięte ani zmodyfikowane przez tę zmianę. Zawierają dane o innym modelu tożsamości (IDFV); nie przypisujemy ich automatycznie do nowych kont. Ich usunięcie lub migracja wymaga osobnej decyzji właściciela i konkretnej operacji na danych.

## Obsługa zgłoszeń

W konsoli sprawdzać otwarte dokumenty `communityReports`. W `communityMessages` ustawienie `moderationStatus=hidden` ukrywa treść; `communityAccounts.suspended=true` blokuje konto i jego treści w odpowiedziach. Klient aktualizuje widok przy kolejnym pobraniu. Nie zmieniać autora ani współrzędnych dokumentu podczas moderacji.

Alternatywnie operator z odpowiednimi Application Default Credentials może użyć skryptu:

```sh
node backend/scripts/moderate.cjs --project PROJECT_ID --action list
node backend/scripts/moderate.cjs --project PROJECT_ID --action hide --id MESSAGE_ID
```

Operacje zmieniające dane są domyślnie próbą bez zapisu; wymagają jawnego `--apply`. Zamykanie zgłoszenia: `--action resolve --id REPORT_ID --apply`.

## Ograniczenia i koszty do obserwowania

- Konto jest anonimowe. Blokady i limity są powiązane z UID; utworzenie nowego konta może je obejść. Tożsamość anonimowa nie zapewnia trwałego zakazu dostępu dla konkretnej osoby.
- Podana pozycja nie dowodzi fizycznej obecności; GPS można sfałszować. App Check i limity ograniczają nadużycia, nie eliminują ich całkowicie.
- Odpowiedź jest regionalna, profile ograniczone do 100, czat do 50 wpisów na stronę. Klient utrzymuje maksymalnie 200 wiadomości w pamięci. Nadmiernie zatłoczony obszar daje jawny błąd zamiast niepełnych, pozornie poprawnych wyników.
- Odczyty odświeżają się co około 15 sekund wyłącznie przy aktywnej aplikacji; czat jest pobierany tylko po jego otwarciu. Obecność odnawia się co 30 sekund, a zmiany muzyki z uwzględnieniem limitu 5 sekund.
- `maxInstances=5` na funkcję ogranicza skalowanie obliczeń, ale nie jest limitem rachunku. Przed uruchomieniem ustawić alerty kosztów i obserwować wywołania, odczyty, opóźnienia i odrzucenia App Check. Alert budżetu nie zatrzymuje automatycznie wydatków.
- Nie zmierzono jeszcze zużycia energii na fizycznym urządzeniu. Odczyt Muzyki i App Attest trzeba sprawdzić na urządzeniu z odpowiednimi uprawnieniami.
