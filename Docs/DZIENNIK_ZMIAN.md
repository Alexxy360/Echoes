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

## CK-00 — 2026-11-12 — plan migracji i zasady prowadzenia zmian

Stan: wykonano dokumentację; migracja kodu do CloudKit jeszcze nie jest wdrożona. Commit poprzednich fundamentów: `466f45ce9b6d69ca18d4a81bd5ebb6bd1470603b`. Commit tego wpisu ma ID CK-00 w tytule.

Wykonane modyfikacje:

- `Docs/PLAN_MIGRACJI_CLOUDKIT.md`: dodano kolejność CK-01–CK-08, model trwałych i tymczasowych danych, profile i CKAsset, kryteria odbioru, etap sprawdzenia ról, wymagania moderacji i kasowania, odłączenie Firebase oraz procedurę produkcyjną.
- `Docs/DZIENNIK_ZMIAN.md`: utworzono rejestr wykonanych zmian, retrospektywny wpis FOUND-01 i obowiązek uzupełniania dziennika przy każdym kolejnym commicie; zapisano stałą zasadę commit/push większych etapów.
- `README.md`: wskazano nowy kierunek migracji i oba dokumenty; zaznaczono, że aktualny klient nadal używa Firebase.

Weryfikacja: sprawdzono oficjalny model baz i kont CloudKit, zgodność plików z wcześniejszą weryfikacją oraz poprawność odnośników lokalnych i diff. W tym etapie zmieniono wyłącznie dokumentację; nie ponawiano testów aplikacji.

Ograniczenia: nie skonfigurowano kontenera Apple ani nie promowano schematu. Dane w chmurze nie zostały zmienione. Szczegóły przyszłych funkcji produktu pozostają do ustalenia; nie obiecujemy gotowych zabezpieczeń ani braku kosztów ewentualnej dodatkowej usługi. Push nie oznacza wdrożenia aplikacji ani sukcesu zdalnego CI.

## CK-01a — 2026-11-12 — rozpoznanie konta, architektura i preflight

Stan: wykonana niezależna część CK-01; pełny odbiór uprawnień CloudKit pozostaje otwarty.

- `Docs/CLOUDKIT_ARCHITEKTURA.md`: dodano fakty z konta i lokalnego profilu, macierz właściciela/odbiorców/operatora oraz warianty A/B z konkretnymi różnicami ochrony.
- `scripts/cloudkit-preflight.py`: dodano narzędzie tylko do odczytu, sprawdzające jawny kontener, usługę CloudKit, środowisko i profil; bez sekretów w wynikach i bez zgadywania kontenera.
- `scripts/test_cloudkit_preflight.py`: 5 testów offline granic konfiguracji.
- `Docs/CLOUDKIT_WERYFIKACJA.md`: oddzielono testy lokalne od niewykonanych prób na prawdziwych kontach; zapisano kryteria dalszego odbioru.
- `Docs/PLAN_MIGRACJI_CLOUDKIT.md`: uaktualniono postęp bez oznaczania CK-01 jako ukończonego.
- `.gitignore`: dodano wykluczenie plików cache Pythona.

Weryfikacja: 5 testów Python przeszło; obecne entitlements poprawnie odrzucone jako nieskonfigurowane. Po samodzielnej akceptacji umowy przez właściciela potwierdzono dostęp do listy App IDs. Nie zapisano danych osobowych z konta w repozytorium. Rejestracja App ID oczekuje na osobne potwierdzenie; nie zmieniono danych ani schematu chmury.

## CK-02a — 2026-11-12 — niezależna podstawa konta iCloud

Stan: pakiet gotowy i sprawdzony lokalnie; pełny adapter oraz test prawdziwego konta pozostają do wdrożenia.

- `EchoesCloudKit/Package.swift`: nowy pakiet Swift 6, iOS 17+/macOS 14+, bez zewnętrznych zależności. Minimum głównej aplikacji pozostaje iOS 26.1.
- `EchoesCloudKit/Sources/EchoesCloudKit/CloudKitConfiguration.swift`: jawny identyfikator kontenera i środowisko, walidacja zgodności uprawnień; brak automatycznie wymyślonego kontenera.
- `EchoesCloudKit/Sources/EchoesCloudKit/CloudKitAccountSession.swift`: natywne accountStatus/userRecordID, osobna testowalna sesja, natychmiastowe usunięcie starej tożsamości, revision do izolacji cache, odrzucanie starych odpowiedzi, obsługa anulowania i cyklu obserwatora.
- `EchoesCloudKit/Sources/EchoesCloudKit/CloudKitFailure.swift`: bezpieczne komunikaty, retryAfter, konflikt i częściowy sukces bez automatycznego ponawiania potencjalnie wykonanych zapisów.
- `EchoesCloudKit/Tests/EchoesCloudKitTests/CloudKitTests.swift`: 8 testów zachowania z kontrolowanymi odpowiedziami konta.
- `EchoesCloudKit/README.md`: zakres modułu, sposób użycia i ograniczenia testów.
- `.github/workflows/checks.yml`: dodano testy nowego pakietu i preflight do kontroli iOS.
- `README.md`, `Docs/PLAN_MIGRACJI_CLOUDKIT.md`: wskazano przygotowany pakiet i rzeczywisty postęp migracji.

Weryfikacja: 8 testów Swift przeszło; pakiet skompilował się dla iOS Simulator arm64/x86_64. Do tego 5 testów preflight z CK-01a przeszło w oryginalnym repozytorium. Testy nie korzystają z kont iCloud, nie testują ról na serwerze i nie zastępują prób dwóch prawdziwych kont.

Ograniczenia: nie przełączono aplikacji z Firebase, nie przypisano jeszcze kontenera i nie utworzono rekordów. Nie wdrożono nowej polityki publiczności danych ani dodatkowego hostingu.

## CK-01b — 2026-11-12 — wyjaśnienie rejestracji i modelu dostępu

- `Docs/CLOUDKIT_DECYZJE_DOSTEPU.md`: rozdzielono Bundle ID w projekcie, App ID w Apple i rejestrację Firebase; wyjaśniono filtr 3 km, publiczność danych i egzekwowanie zasad na przykładach. Dodano konsekwencje dla blokad, spamu, zgłoszeń i kasowania oraz propozycję rozdziału danych.
- Rejestracja App ID nie została zatwierdzona. Automatyczna kontrola odrzuciła Register do czasu bezpośredniej zgody. Właściciel poprosił o wyjaśnienia, a nie zatwierdził zapis. Nie przyjęto wariantu A/B ani nie zmieniono publiczności danych.
- Weryfikacja: sprawdzono treść względem obserwowanej listy identyfikatorów i dokumentacji Apple, poprawność odnośników i diff; zmiana wyłącznie dokumentacyjna.

## CK-00b — 2026-11-12 — budżet początkowy i późniejsza rozbudowa

- `Docs/STRATEGIA_KOSZTOW.md`: dodano strategię 0 zł dodatkowych opłat za usługi na start, oddzielono istniejące członkostwo Apple, opisano granice pierwszej wersji, zachowanie wymagań prywatności i moderacji oraz przygotowanie do późniejszego dodania usług/migracji.
- `Docs/PLAN_MIGRACJI_CLOUDKIT.md`: wpisano priorytet budżetowy i wymóg konkretnej zgody przed dodatkowymi opłatami. Przychód nie jest gwarancją, że wcześniej nie pojawią się limity; opisano monitoring oraz opcje ograniczenia funkcji.
- Nie uruchomiono płatności, nie zatwierdzono App ID ani zmiany dostępu do rekordów.
- Weryfikacja: sprawdzono aktualne warunki CloudKit i throttling w dokumentacji Apple, odnośniki lokalne oraz diff. Zmiany wyłącznie dokumentacyjne; nie powtarzano testów aplikacji.

## CK-03a — 2026-11-12 — prywatny profil i lokalne przygotowanie avatarów

Stan: zaimplementowane komponenty warstwy danych i zdjęć; jeszcze niewłączone do głównego interfejsu. Publiczny profil, upload CKAsset oraz odbiór dwóch kont pozostają do realizacji.

- `EchoesCloudKit/Package.swift`: dodano zależność od lokalnego EchoesCore, bez zewnętrznej usługi i opłat.
- `EchoesCloudKit/Sources/EchoesCloudKit/PrivateProfileStore.swift`: dodano model prywatnego pseudonimu, wersjonowany kodek CKRecord, natywny magazyn wyłącznie privateCloudDatabase oraz testowalny store. Wymagane jest poprawne wczytanie przed zapisem; awaria sieci nie jest interpretowana jako pusty profil. Zapis zachowuje change tag i obce pola, odrzuca konflikty i nowszy schemat. Zmiana konta natychmiast ukrywa cache poprzedniego użytkownika; także błąd zapisu/usunięcia nie przywraca obcych danych.
- `EchoesCloudKit/Tests/EchoesCloudKitTests/PrivateProfileTests.swift`: 9 testów profilu, w tym spóźnione odczyty/zapisy, konflikt bez ponowienia, brak odczytu przed zapisem, offline, nowszy schemat, zachowanie dodatkowych pól oraz usunięcie rekordu bez usuwania konta Apple.
- `EchoesCloudKit/Sources/EchoesCloudKit/AvatarPreparer.swift`: dodano lokalne przygotowanie zdjęć z limitami wejścia, wymiarów i wyniku; miniatury, orientacja w pikselach oraz usunięcie źródłowych metadanych GPS/aparatu. Brak uploadu.
- `EchoesCloudKit/Tests/EchoesCloudKitTests/AvatarTests.swift`: 4 testy syntetycznych zdjęć — GPS/metadata, orientacja, wymiary/transfer oraz odrzucanie nieprawidłowych i zbyt dużych danych.
- `EchoesCloudKit/README.md`: opisano format rekordu, zakres komponentów i sposób bezpiecznego użycia.
- `Docs/PLAN_MIGRACJI_CLOUDKIT.md`, `Docs/CLOUDKIT_WERYFIKACJA.md`: dodano rzeczywisty postęp i wyniki bez deklarowania zakończenia CK-03.

Weryfikacja: 21 testów pakietu przeszło (8 konta, 9 profilu, 4 avatarów); wykonano kompilacje modułu dla iOS opisane w raporcie weryfikacji. Testy używają stubów CloudKit i obrazów syntetycznych. Nie przesłano danych użytkowników do chmury i nie zmieniono polityki publiczności danych.

## CK-01c / CK-02b — 2026-11-12 — konfiguracja Apple i podpisana próba prywatna

Stan: faktyczne połączenie z CloudKit Development jednego konta potwierdzone. Pełne CK-01/CK-02 nadal otwarte do odbioru dwóch kont, adaptera i zasad dostępu.

- Po oddzielnych, konkretnych zgodach właściciela zarejestrowano App ID Echoes `mpvEcho.Echo`, utworzono kontener `iCloud.mpvEcho.Echo` w zespole `22YC9RAP4P` i przypisano tylko do tego App ID. Ponowne otwarcie konfiguracji potwierdziło jeden aktywny kontener; konsola potwierdziła Dev. Właściciel sam zaakceptował wcześniejszą umowę Apple.
- Po osobnej zgodzie wygenerowano zgodny profil, podpisano Debug, zainstalowano go na iPhonie 15 Pro bez odinstalowania/kasowania danych i wykonano ograniczony test syntetyczny. Nie uruchomiono dodatkowo płatnej usługi.
- `Echoes.xcodeproj/project.pbxproj`: dodano lokalną zależność EchoesCloudKit oraz osobne entitlements Debug. Porównano Package.resolved; wersje i rewizje zewnętrznych pakietów pozostają te same, plik nie wymagał zmiany.
- `Echo/Echo-Debug.entitlements`: jawny potwierdzony kontener, CloudKit, wyłącznie Development. Release zachowuje wcześniejszy plik do CK-06.
- `Echo/EchoApp.swift`: przełącznik Debug `ECHOES_CLOUDKIT_PROBE` uruchamia diagnostykę bez Firebase, GPS i muzyki; zwykłe ścieżki aplikacji pozostają poprzednie.
- `Echo/Services/CloudKitProbe.swift`, `Echo/Views/CloudKitProbeView.swift`: test dostępności konta, zapisu/odczytu nonce i metadanych autora oraz kasowania tylko UUID rekordu testowego. Brak automatycznych ponowień; próba sprzątania także po błędzie odpowiedzi, osobny błąd sprzątania, izolacja zmiany konta. Lokalny raport ma czas/runIdentifier, bez raw userRecordID i danych profilu. Implementacja i przełączniki wyłącznie Debug.
- Skorygowano diagnostykę autora: prywatny rekord zwrócił CKCurrentUserDefaultName zamiast resolved userRecordID. Drugi przebieg potwierdził alias, nonce i cleanup. Nie używamy tego porównania jako publicznej reguły dostępu. Oba rekordy testowe usunięto.
- `scripts/cloudkit-preflight.py`, `scripts/test_cloudkit_preflight.py`: rozróżniono zakres profilu Apple (`*` usług, lista środowisk) od konkretnych uprawnień podpisanej aplikacji. Kontener nadal musi być jawny. Dodano 3 testy granic; łącznie 8.
- `EchoesCloudKit/Sources/EchoesCloudKit/CloudKitConfiguration.swift`: doprecyzowano komentarz, że walidacja dotyczy konkretnego podpisu aplikacji, a nie zakresu profilu. Bez zmiany zachowania.
- `Docs/CLOUDKIT_DIAGNOSTYKA.md`, `Docs/evidence/cloudkit-private-probe-development.json`: instrukcja i bezpieczny raport z prawdziwego urządzenia.
- `README.md`, `EchoesCloudKit/README.md`, `Docs/CLOUDKIT_ARCHITEKTURA.md`, `Docs/CLOUDKIT_WERYFIKACJA.md`, `Docs/CLOUDKIT_DECYZJE_DOSTEPU.md`, `Docs/STRATEGIA_KOSZTOW.md`, `Docs/PLAN_MIGRACJI_CLOUDKIT.md`: aktualizacja stanu faktycznego, ograniczeń i decyzji właściciela o pośredniku ograniczającym odczyt z uprzednim badaniem darmowego limitu.

Weryfikacja: podpisany Debug na iPhonie — konto, zapis, odczyt, autor i cleanup poprawne; preflight podpisu/profilu entitlements-match; 8 testów preflight; kompilacje całej aplikacji Debug (urządzenie/symulator) i Release bez podpisywania; 4 testy UI demo przeszły. Wcześniejsze 21 testów pakietu przeszło, jego zachowanie nie zmieniło się w tym etapie.

Ograniczenia: nie ma jeszcze testu kont A/B, publicznych ról, zmiany konta/offline na urządzeniu, uploadu zdjęć, produkcyjnej moderacji ani ukończonej migracji. Nie promowano schematu Production, nie przenoszono dawnych danych i nie dodano sekretów/profili do Git. Wybrany pośrednik wymaga następnego prototypu; brak zgody na dodatkowe opłaty.
