# Echoes

> Kierunek rozwoju: migracja do CloudKit. Aktualny kod nadal korzysta z adaptera Firebase. Kolejność prac i odbiór opisuje [plan migracji](Docs/PLAN_MIGRACJI_CLOUDKIT.md), a wykonane modyfikacje — [dziennik zmian](Docs/DZIENNIK_ZMIAN.md).

Aplikacja iOS do odkrywania muzyki i rozmów w okolicy. Projekt edukacyjny inspirowany „Echoes” Pink Floyd; zachowuje mapę MapKit i kolorystykę pierwotnego prototypu.

## Wymagania

- iOS / iPadOS **26.1+**, Xcode **26.1+** (sprawdzono Xcode 27.1).
- Backend: **Node.js 22**, Java 21+ do emulatora Firestore; lokalne testy wykonano na Java 25.
- W produkcji: Firebase Auth Anonymous, App Check oraz wdrożone callable Cloud Functions i Firestore. Cloud Functions wymaga planu Blaze.
- Apple Music jest opcjonalne; integracja dotyczy aplikacji Muzyka, nie Spotify.

## Zachowanie i prywatność

Aplikacja uruchamia się z ukrytym profilem. Uprawnienie When In Use jest wymagane dopiero przy użyciu lokalizacji; Always i praca GPS w tle nie są włączone. Widoczność profilu oraz udostępnianie muzyki są osobnymi wyborami.

Bieżąca pozycja służy do zapytań o okolicę i jest przesyłana do backendu. Backend zapisuje wyłącznie pozycję przybliżoną do siatki około 500 m; nie przechowuje dokładnej trasy GPS. Publiczna mapa pokazuje przybliżone profile. Czat dotyczy okolicy około 3 km, z uwzględnieniem przybliżenia miejsca wiadomości, i nie zwraca współrzędnych wiadomości odbiorcom.

Obecność wygasa po 10 minutach bez odnowienia, wiadomości po 2 godzinach, zgłoszenia po 30 dniach. Widoczność wygasa niezależnie od fizycznego kasowania TTL. Utrata sieci może opóźnić natychmiastowe ukrycie profilu, co aplikacja sygnalizuje. Pseudonim i akceptacja zasad pozostają w UserDefaults; wiadomości są przechowywane przez klienta wyłącznie w pamięci procesu.

Backend ogranicza zapytania przestrzennie, sprawdza odległość przed wyborem strony wyników, uwierzytelnia autora i wymaga App Check poza emulatorami. Zapisy są limitowane, a ponowienie wiadomości z tym samym identyfikatorem jest idempotentne. Pozycja przekazana przez telefon nie jest dowodem fizycznego pobytu — nie obiecujemy odporności na fałszowanie GPS.

## Uruchomienie

1. Otwórz **Echoes.xcodeproj** i wspólny schemat **Echoes**.
2. Dodaj własny GoogleService-Info.plist do katalogu Echo, zgodny z projektem Firebase oraz Bundle ID aplikacji. Plik jest ignorowany przez Git.
3. Wybierz własny zespół podpisywania dla urządzenia.
4. Wdrożenie usług opisuje [Docs/DEPLOYMENT.md](Docs/DEPLOYMENT.md). Nowy klient nie będzie działał z samymi starymi regułami testowymi.

Do obejrzenia interfejsu bez backendu dodaj do zmiennych środowiska schematu Debug **ECHOES_DEMO_MODE=1**. To fikcyjne dane demonstracyjne, nie test produkcyjnego Firebase. Zmienna jest ignorowana w Release.

Do pracy z emulatorami dodaj **ECHOES_USE_EMULATORS=1** i uruchom lokalny backend. Debug automatycznie używa projektu demo-echoes. Domyślny host dla symulatora: 127.0.0.1; urządzenie fizyczne wymaga adresu lokalnego komputera w ECHOES_EMULATOR_HOST.

## Testy

```sh
swift test --package-path EchoesCore
npm ci --ignore-scripts
npm --prefix backend ci --ignore-scripts
npm run test:backend
npm run test:integration
```

Testy UI uruchom przez Product → Test w schemacie Echoes. Testują prywatne wejście, wysłanie wiadomości, błąd bez utraty szkicu, ustawienia i największy Dynamic Type. Korzystają wyłącznie z trybu demonstracyjnego. Skrypt scripts/ci-ios.py automatyzuje kompilację Release i testy UI w CI; w jego środowisku może uruchomić dostępny symulator.

Workflow [.github/workflows/checks.yml](.github/workflows/checks.yml) sprawdza Swift, backend, reguły w emulatorze, audyt npm i aplikację iOS. Nie wdraża produkcji ani nie używa kluczy administracyjnych.

Zależności runtime backendu i narzędzia mają pliki blokady. Root package.json zawiera jawne poprawki pośrednich zależności Firebase CLI; ich zgodność sprawdzono przebiegiem emulatorów. Przy aktualizacjach ponawiać te testy oraz sprawdzać pakowanie i wdrożenie na środowisku testowym.

## Struktura

- EchoesCore — modele, walidacja, czas, linki oraz testowalna sesja społecznościowa.
- Echo/Services — adapter Firebase, GPS, zdarzenia aplikacji Muzyka i składanie zależności.
- Echo/Views oraz ContentView i ChatView — komponenty SwiftUI i dostępne stany interfejsu.
- backend/src — funkcje serwerowe i testy domeny oraz integracji.
- firestore.rules — blokada bezpośredniego dostępu klienta do dokumentów.
- firestore.indexes.json — indeksy i konfiguracja TTL do wdrożenia.
- Docs/DEPLOYMENT.md — wdrożenie, ograniczenia, koszty i moderacja.

## Przed publikacją

Właściciel musi podać kontakt do obsługi (SUPPORT_URL), ustanowić proces moderacji oraz aktywować i sprawdzić usługi Firebase. Konfiguracja App Store privacy musi odpowiadać rzeczywistemu wdrożeniu. Własny manifest PrivacyInfo.xcprivacy opisuje użycie UserDefaults i kategorie danych.

Stare kolekcje users i messages nie są automatycznie migrowane ani usuwane. Fizyczne testy Apple Music, App Attest, baterii i urządzeń innych niż zweryfikowany symulator pozostają częścią odbioru urządzeniowego. Kod jest nadal projektem edukacyjnym; ten plik nie ustanawia nowej licencji.

## Przygotowywany moduł CloudKit

[EchoesCloudKit](EchoesCloudKit/README.md) zawiera obsługę konta iCloud, prywatnego profilu i lokalnego przygotowania zdjęć. Jest zależnością aplikacji, lecz używa go na razie tylko osobny [tryb diagnostyczny Debug](Docs/CLOUDKIT_DIAGNOSTYKA.md). Podpisany Debug z kontenerem `iCloud.mpvEcho.Echo` przeszedł test losowego rekordu prywatnego na iPhonie. Zwykłe funkcje społecznościowe i Release nadal korzystają z dotychczasowej ścieżki Firebase.

Testy: `swift test --package-path EchoesCloudKit` i `python3 scripts/test_cloudkit_preflight.py`. Preflight uruchamiać dla rzeczywistych uprawnień podpisanej aplikacji i jej profilu zgodnie z instrukcją diagnostyczną. Sam preflight nie potwierdza połączenia ani ról CloudKit.

[Architektura i warianty dostępu](Docs/CLOUDKIT_ARCHITEKTURA.md) oraz [wyniki weryfikacji](Docs/CLOUDKIT_WERYFIKACJA.md) oddzielają gotowy kod lokalny od pozostałego odbioru CloudKit.

[Pośrednik z darmowym limitem](Docs/CLOUDKIT_POSREDNIK_FREE.md): po decyzji o ograniczaniu odczytu zbadano Workers Free; `gateway` zawiera komponenty podpisywania/diagnostyki Development oraz prototyp HTTP/SQLite oraz lokalny verifier Apple JWT z 40 testami lokalnymi. Kod wdrożono w Workers Free; kontrole HTTP i syntetyczny test zapisu/odczytu/usunięcia CloudKit z hostingu przeszły po poprawkach zgodności Workers. Ponowienie zwraca raport z SQLite. Próba pozostaje wyłączona, bez sekretów w aktywnej konfiguracji. Lokalny test S2S zapisu, odczytu i usunięcia przeszedł po skonfigurowaniu osobnej roli dla tożsamości klucza; S2S podlega rolom konta operatora. Nie jest jeszcze wdrożonym backendem ani gotowym uwierzytelnianiem.

[Weryfikacja logowania Apple](Docs/APPLE_LOGOWANIE_GATEWAY.md): 13 nowych testów syntetycznych. Komponent nie jest podłączony do HTTP i nie wdraża jeszcze wyzwania ani sesji; rzeczywiste logowanie użytkowników pozostaje przed odbiorem.
