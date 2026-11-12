# Dziennik zmian Echoes

Ten plik zawiera wyłącznie wykonane zmiany. Planowane prace są w [planie migracji](PLAN_MIGRACJI_CLOUDKIT.md). Daty dotyczą Europe/Warsaw. Starsze prace z tego czatu zebrano retrospektywnie w FOUND-01; wcześniejszą historię projektu zachowuje Git.

## Zasady prowadzenia

Każda modyfikacja funkcjonalna lub techniczna musi zostać opisana we wpisie: ID, data, cel, zmiana zachowania, pliki, weryfikacja oraz ograniczenia. Większy etap ma osobny commit i push do gałęzi roboczej; wpis jest częścią tego samego commitu. Poprawki po błędzie dopisujemy jawnie, nie zacierając historii. Commit odnajdujemy po ID w tytule (`git log --all --oneline --grep=CK-00`). Nie wpisujemy do dziennika tokenów, kluczy ani danych użytkowników.

## FOUND-01 — 2026-11-12 — wcześniejsze fundamenty i punkt powrotu

Stan: wdrożone lokalnie; utrwalane w commicie z ID FOUND-01. Baza: cc046c08631515c0939711705530c4ceb6a2edce. To implementacja Firebase przygotowana przed decyzją o CloudKit, nie zakończona migracja.

Wykonane zmiany:

1. Dodano EchoesCore: modele, walidację, linki Apple Music i testowalną sesję; wydzielono GPS, muzykę i adapter danych.
2. Zaktualizowano Firebase do 12.19.3; dodano Auth, Functions i App Check, usunięto produkty klienckiego Firestore i Analytics.
3. Przygotowano backend: regionalne wyniki, limity, idempotencja, autor związany z UID, blokady, zgłoszenia i usuwanie własnych danych. Dodano deny-all reguły klienta, indeksy i konfigurację TTL.
4. Profil jest domyślnie ukryty, muzyka wymaga osobnego wyboru; pozycja publiczna przybliżona. Usunięto GPS w tle i żądanie Always.
5. Poprawiono najnowsze wiadomości, stronicowanie, aktualność GPS, wygasanie według czasu serwera i ochronę przed spóźnionymi odpowiedziami.
6. Szkic pozostaje po błędzie, ponowienie jest idempotentne; błędy są widoczne wewnątrz arkuszy. Dodano rzeczywiste stany ładowania i dostępne kontrolki.
7. Dopracowano duży tekst na mapie, aktualność karty profilu oraz ustawienia prywatności, blokowania i usuwania.
8. Muzyka odświeża się po zmianie odtwarzacza i przy powrocie do aplikacji; limit tytułu odpowiada UTF-16 serwera. GPS odświeża się również przy postoju.
9. Dodano własny manifest prywatności, wykluczono GPX z pakietu, rozdzielono Info.plist Debug/Release; wyjątek sieci lokalnej wyłącznie w Debug.
10. Dodano testy, workflow CI, blokady zależności, instrukcję wdrożenia oraz zestawienie A01–A25. Poprawiono pośrednie zależności CLI; audyty npm zgłosiły 0 podatności w chwili kontroli.

Weryfikacja wykonana przed wpisem: 13 testów Swift, 5 jednostkowych backendu, 7 integracyjnych emulatorów, 4 UI na iPhone 17 Pro/iOS 26.1; wszystkie przeszły. Debug i Release skompilowane bez podpisywania; po przeniesieniu do oryginalnego repozytorium ponownie przeszły Release i 4 testy UI. Zrzuty UI obejrzano. Oba pakiety zawierają manifest aplikacji i nie zawierają GPX ani pakietów Analytics. Przed commitem porównano SHA-256 plików ze zweryfikowaną wersją.

Ograniczenia: produkcyjny Firebase nie został wdrożony; usług i starych danych w chmurze nie zmieniono. Nie wykonano odbioru App Attest/Apple Music i pomiarów na fizycznym urządzeniu. Zdalny CI nie był dotąd potwierdzony. Szczegóły: [status fundamentów](FUNDAMENTY_STATUS.md).

Dokładny zakres plików tego etapu (pełne różnice w commicie FOUND-01):

- Dodano lub zmodyfikowano `.firebaserc`.
- Dodano lub zmodyfikowano `.github/workflows/checks.yml`.
- Dodano lub zmodyfikowano `.gitignore`.
- Dodano lub zmodyfikowano `.swift-format`.
- Dodano lub zmodyfikowano `Docs/DEPLOYMENT.md`.
- Dodano lub zmodyfikowano `Docs/FUNDAMENTY_STATUS.md`.
- Dodano lub zmodyfikowano `Echo/ChatView.swift`.
- Dodano lub zmodyfikowano `Echo/ContentView.swift`.
- Dodano lub zmodyfikowano `Echo/Echo.entitlements`.
- Dodano lub zmodyfikowano `Echo/EchoApp.swift`.
- Dodano lub zmodyfikowano `Echo/Echoes-Debug-Info.plist`.
- Dodano lub zmodyfikowano `Echo/Echoes-Info.plist`.
- Dodano lub zmodyfikowano `Echo/PrivacyInfo.xcprivacy`.
- Dodano lub zmodyfikowano `Echo/Services/AppServices.swift`.
- Dodano lub zmodyfikowano `Echo/Services/CommunityAPI.swift`.
- Dodano lub zmodyfikowano `Echo/Services/LocationService.swift`.
- Dodano lub zmodyfikowano `Echo/Services/MusicService.swift`.
- Dodano lub zmodyfikowano `Echo/Views/MapComponents.swift`.
- Dodano lub zmodyfikowano `Echo/Views/SessionFeedback.swift`.
- Dodano lub zmodyfikowano `Echo/Views/SettingsView.swift`.
- Dodano lub zmodyfikowano `Echo/Views/UserProfileView.swift`.
- Dodano lub zmodyfikowano `Echo/Views/WelcomeView.swift`.
- Dodano lub zmodyfikowano `Echoes.xcodeproj/project.pbxproj`.
- Dodano lub zmodyfikowano `Echoes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Dodano lub zmodyfikowano `Echoes.xcodeproj/xcshareddata/xcschemes/Echoes.xcscheme`.
- Dodano lub zmodyfikowano `EchoesCore/Package.swift`.
- Dodano lub zmodyfikowano `EchoesCore/Sources/EchoesCore/Community.swift`.
- Dodano lub zmodyfikowano `EchoesCore/Sources/EchoesCore/CommunitySession.swift`.
- Dodano lub zmodyfikowano `EchoesCore/Tests/EchoesCoreTests/CommunityTests.swift`.
- Dodano lub zmodyfikowano `EchoesCore/Tests/EchoesCoreTests/SessionTests.swift`.
- Dodano lub zmodyfikowano `EchoesUITests/EchoesUITests.swift`.
- Dodano lub zmodyfikowano `README.md`.
- Dodano lub zmodyfikowano `backend/.env.example`.
- Dodano lub zmodyfikowano `backend/package-lock.json`.
- Dodano lub zmodyfikowano `backend/package.json`.
- Dodano lub zmodyfikowano `backend/scripts/moderate.cjs`.
- Dodano lub zmodyfikowano `backend/src/domain.ts`.
- Dodano lub zmodyfikowano `backend/src/index.ts`.
- Dodano lub zmodyfikowano `backend/src/service.ts`.
- Dodano lub zmodyfikowano `backend/src/test/domain.test.ts`.
- Dodano lub zmodyfikowano `backend/src/test/service.integration.ts`.
- Dodano lub zmodyfikowano `backend/tsconfig.json`.
- Dodano lub zmodyfikowano `firebase.json`.
- Dodano lub zmodyfikowano `firestore.indexes.json`.
- Dodano lub zmodyfikowano `firestore.rules`.
- Dodano lub zmodyfikowano `package-lock.json`.
- Dodano lub zmodyfikowano `package.json`.
- Dodano lub zmodyfikowano `scripts/ci-ios.py`.
- Usunięto zastąpiony plik `Echo/ChatManager.swift`.
- Usunięto zastąpiony plik `Echo/LocationManager.swift`.
- Usunięto zastąpiony plik `Echo/NearbyUser.swift`.
