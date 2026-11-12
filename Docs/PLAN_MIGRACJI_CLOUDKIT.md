# Plan migracji Echoes do CloudKit

Data: 12 listopada 2026. Kierunek wybrany przez właściciela: CloudKit. Status: CK-01 w realizacji; wykonano rozpoznanie konta, macierz architektury i preflight; klient nadal korzysta z adaptera Firebase. Nie wdrożono schematu CloudKit ani migracji danych.

## Cel i zakres

Przenieść istniejącą mapę, obecność muzyczną i lokalny czat do architektury opartej o CloudKit. Zachować poprawki sesji, prywatnego startu, GPS, muzyki, szkicu i dostępności. Przygotować model do trwałych profili i zdjęć oraz dalszych funkcji społecznościowych. Konkretne nowe funkcje produktu wymagają osobnej specyfikacji; ten plan nie zakłada automatycznego dodania feedu, znajomych czy prywatnego komunikatora.

Nie zakładamy, że sama zmiana bazy zapewnia wszystkie dotychczasowe zabezpieczenia ani że wyeliminuje koszt każdej przyszłej usługi. Najpierw sprawdzamy granice CloudKit w małym prototypie, potem migrujemy funkcje.

## Zasady realizacji i Git

- Każdy większy, spójny etap: implementacja → odpowiednia weryfikacja → aktualizacja Docs/DZIENNIK_ZMIAN.md i tego planu → commit → push do origin na gałąź roboczą.
- Bieżąca gałąź: codex/foundation-hardening. Nie wykonujemy force push ani automatycznego merge do main. W razie odrzucenia push sprawdzamy różnice; nie nadpisujemy zdalnych commitów.
- Dziennik opisuje każdą zmianę funkcjonalną i techniczną z listą plików, przyczyną, wynikiem testów i ograniczeniami. Drobne poprawki mogą być jednym wpisem, ale wszystkie muszą być wymienione. Historia Git zawiera dokładny diff każdej linii.
- Wpis dziennika trafia do tego samego commitu co zmiana. Identyfikator etapu w tytule commitu pozwala go znaleźć bez wpisywania własnego hasha do własnej treści. Stan push sprawdzamy przez porównanie HEAD ze zdalną gałęzią; nie deklarujemy sukcesu przy błędzie.
- Git nie zawiera kluczy CloudKit server-to-server, tokenów, profili podpisywania, konfiguracji GoogleService-Info.plist ani eksportów danych użytkowników.
- Dotychczasowe poprawki Firebase zostają utrwalone jako punkt powrotu, a nie wdrożone do chmury. Wdrożenie aplikacji/usług jest oddzielne od push kodu.

## Etapy i kryteria odbioru

### CK-00 — punkt powrotu i dokumentacja

- [x] Sprawdzić repozytorium i zgodność wcześniejszego kodu z testowaną wersją.
- [x] Przygotować plan, zasady Git i dziennik dotychczasowych modyfikacji.
- [x] Utrwalić wcześniejsze fundamenty w osobnym commicie.

Commit punktu powrotu: `466f45ce9b6d69ca18d4a81bd5ebb6bd1470603b`. Push jest wykonywany dla ukończonego etapu; aktualny wynik potwierdza zgodność HEAD z origin/codex/foundation-hardening.

### CK-01 — prototyp uprawnień i decyzje architektoniczne

Postęp: sprawdzono zespół, lokalny profil i dostęp do portalu, przygotowano [macierz i warianty architektury](CLOUDKIT_ARCHITEKTURA.md) oraz narzędzie preflight z testami. Właściciel odblokował dostęp przez samodzielną akceptację umowy Apple. Rejestracja App ID, kontener i test dwóch kont oczekują; etap nie jest zakończony. [Dowody i pozostałe próby](CLOUDKIT_WERYFIKACJA.md).

1. Sprawdzić dostęp zespołu do iCloud/CloudKit, Bundle ID i istniejące kontenery. Nie wymyślać identyfikatora kontenera bez sprawdzenia konta Apple.
2. W środowisku Development przetestować odczyt/zapis dwóch użytkowników, zmianę konta iCloud, brak konta i niedostępność sieci. Nie publikować schematu produkcyjnego na tym etapie.
3. Sporządzić Docs/CLOUDKIT_ARCHITEKTURA.md: macierz kto może tworzyć, odczytywać, zmieniać i usuwać każdy typ danych. Zweryfikować bezpośrednie operacje klienta z pominięciem UI.
4. Udokumentować osobno granice: dostęp do publicznych rekordów spoza okolicy, modyfikacja własnych pól, limity antyspamowe, trwała blokada konta, ukrycie treści przez moderatora i poufność zgłoszeń.
5. Wybrać konkretną implementację elementów wymagających zaufanej logiki. Dodatkowy backend/operator jest opcją do sprawdzenia, nie automatycznie uruchamianą usługą płatną.

Odbiór: dowody testów dwóch kont i macierz uprawnień. Niespełnionych wymagań nie zastępujemy filtrem w UI. Jeśli wymagana jest dodatkowa usługa lub zmiana obietnic prywatności, przedstawiamy konkretny wariant, koszt i wpływ przed realizacją tej części. Pozostałe niezależne prace mogą być kontynuowane.

### CK-02 — adapter CloudKit i tożsamość

- Zachować niezależny EchoesCore i wstrzykiwanie zależności. Dopasować CommunityClient do CloudKit, zamiast kopiować do niego założenia Firebase.
- Dodać obsługę konta iCloud oraz izolację cache po zmianie tożsamości; nie traktować identyfikatora Firebase/IDFV jako identyfikatora CloudKit.
- Obsłużyć brak iCloud, restricted, czasową niedostępność, retryAfter, częściowe błędy, anulowanie, konflikty i idempotencję ponowienia.
- Wprowadzić schemat wersjonowany i indeksy w Development. Konfiguracja entitlements i podpisywania zgodna z rzeczywistym kontenerem.
- Zachować niezależny tryb demo. Prawdziwe konto iCloud nie może być zastępowane pozornym sukcesem demo.

Odbiór: testy kontraktu adaptera oraz prawdziwa próba konta iCloud na urządzeniu; testy mocków nie potwierdzają konfiguracji usługi.

### CK-03 — trwały profil i model gotowy na zdjęcia

Projekt roboczy do potwierdzenia w CK-01:

| Dane | Proponowane miejsce | Zasada |
| --- | --- | --- |
| PublicProfile | Public database | Wyłącznie świadomie publiczne pola; pseudonim i odnośnik do avatara. Bez dokładnego GPS, e-maila i prywatnych ustawień. |
| PrivateProfile / Preferences | Private database | Prywatne dane i ustawienia użytkownika; nie zakładać dostępu moderatora do prywatnej bazy. |
| Presence | Public database lub warstwa pośrednia z CK-01 | Dane tymczasowe, przybliżona pozycja; oddzielone od trwałego profilu. |
| Avatar / miniatura | CKAsset | Oddzielne lekkie miniatury; pobierane na żądanie, z limitem rozmiaru i walidacją formatu. |
| LocalMessage | Projekt dostępu z CK-01 | Autor oparty na zaufanej tożsamości/metadatach; treść i miejsce nie dają prawa do dowolnego zapisu. |
| Blocks | Prywatne preferencje + mechanizm egzekwowania z CK-01 | Ukrycie w aplikacji nie jest serwerowym odebraniem uprawnień. |
| ModerationReport / status moderacji | Mechanizm z CK-01 | Poufne zgłoszenia dostępne obsłudze; nie umieszczać ich jako ogólnodostępnych rekordów. |

- Trwały profil nie wygasa razem z obecnością. Zachować rozdział publicznych i prywatnych pól.
- Nie dopisywać każdej relacji i historii do jednego rosnącego rekordu. Przygotować osobne typy rekordów i stronicowanie dla przyszłych list.
- Podstawowy pseudonim migruje lokalnie dopiero po świadomym przypisaniu do bieżącego konta. Nie przypisywać automatycznie dawnych danych IDFV/anonimowych do kont iCloud.
- Mechanizm avatarów przygotować w osobnym etapie; ostateczne pola profilu i ekran jego edycji wynikają ze specyfikacji nowych funkcji.

Odbiór: izolacja prywatnych danych dwóch kont, trwałość po ponownym uruchomieniu, konflikt edycji, bezpieczna zmiana/usuwanie avatara; brak pobierania pełnych zdjęć wraz z każdym odświeżeniem mapy.

### CK-04 — mapa, GPS i muzyka

- Zastąpić wywołania Firebase operacjami adaptera; zachować domyślnie ukryty profil i osobną zgodę na muzykę.
- Zachować wyłącznie foreground GPS, kontrolę wieku/dokładności i przybliżenie pozycji przed publicznym zapisem.
- Zmierzyć geograficzne zapytania CloudKit dla okolicy około 3 km, przy granicach obszarów i większej liczbie rekordów; nie zakładać identycznej semantyki indeksów jak w Firestore.
- Użyć lekkich pól, cache i pobierania zmian; subskrypcje traktować jako sygnał do odświeżenia, a nie gwarancję natychmiastowego dostarczenia.
- Obsłużyć wygasanie, wyłączenie widoczności i spóźnioną odpowiedź, bez ponownego ujawnienia profilu.

Odbiór: późny GPS, zmiana okolicy, zmiana muzyki bez ruchu, tło/powrót, utrata sieci, wygasanie oraz dwie tożsamości. Nie deklarować, że GPS jest dowodem fizycznego pobytu.

### CK-05 — czat, bezpieczeństwo i retencja

- Przenieść stronicowanie i najnowsze wiadomości; zachować szkic po błędzie oraz idempotencję.
- Zaimplementować decyzje CK-01 dotyczące walidacji, moderacji, zgłoszeń, blokad i limitów. Oznaczyć, co jest wymuszane przez usługę, a co stanowi wyłącznie zachowanie klienta.
- Oddzielić wygaśnięcie widoczności od fizycznego kasowania. Określić wykonawcę kasowania i harmonogram także wtedy, gdy autor już nie uruchamia aplikacji; nie obiecywać TTL Firestore w CloudKit.
- Zachować obecne czasy 10 min obecności i 2 h czatu jako punkt wyjścia; trwałych profili i przyszłych wiadomości prywatnych nie obejmować nimi bez osobnej decyzji produktowej.
- Zaprojektować usunięcie danych aplikacji bez usuwania konta Apple. Obsłużyć częściowo wykonaną operację oraz ponowienie.

Odbiór: więcej niż 100 lokalnych wiadomości, odległe rekordy, cofnięcie widoczności, zmiana konta, próby zapisu cudzego rekordu, blokady i usuwanie. Produkcja wymaga działającego procesu moderacji oraz kontaktu wsparcia (właściciel poda go później).

### CK-06 — odłączenie Firebase

- Po odbiorze kluczowych funkcji usunąć SDK Firebase, adapter, inicjalizację, App Check/App Attest używany wyłącznie przez Firebase i jego niepotrzebne ustawienia.
- Zaktualizować manifest prywatności, opisy uprawnień i README zgodnie z faktycznym przetwarzaniem przez iCloud i ewentualną dodatkową usługę.
- Usunąć nieużywany backend Node, reguły i indeksy z aktywnego projektu dopiero po zachowaniu punktu powrotu; dostosować CI do nowej architektury.
- Starych danych i usług Firebase nie usuwać automatycznie. Przygotować inwentarz oraz osobną, odwracalną o ile możliwe procedurę wyłączenia. Nie przenosić starych danych bez ustalonego właściciela i podstawy przypisania.

Odbiór: Debug/Release bez zależności Firebase, działający tryb demo, testy regresji i brak nieużywanych zasobów/sekretów w pakiecie.

### CK-07 — obciążenie i urządzenia

- Ponowić testy Swift i UI z nowym adapterem; wykorzystać workflow Build iOS Apps do budowania i diagnostyki. Zgoda właściciela na iPhone 17 Pro już została udzielona.
- Sprawdzić prawdziwy CloudKit na dwóch kontach/urządzeniach, osobno od testów demo.
- Zmierzyć rozmiar profilu, miniatur, transfer, liczbę operacji, opóźnienia i reakcję na throttling. Dane testowe wyłącznie syntetyczne, z ograniczonym wolumenem i sprzątaniem.
- Zmierzyć baterię, CPU i pamięć na fizycznym urządzeniu; sprawdzić Apple Music, odmowę/cofnięcie zgód, VoiceOver i większe układy.

Odbiór: zapisane wyniki i ograniczenia w Docs/CLOUDKIT_WERYFIKACJA.md; brak deklaracji pomiarów, których nie wykonano.

### CK-08 — produkcja i wydanie

- Przygotować i przejrzeć schemat, indeksy oraz role przed promocją. CloudKit Production ma ograniczenia późniejszych zmian schematu.
- Przeprowadzić kontrolowaną promocję schematu i odbiór środowiska Production; sam push Git nie publikuje CloudKit ani aplikacji.
- Uzupełnić kontakt, proces moderacji, informacje prywatności i deklaracje App Store. Sprawdzić wymagania podpisywania i członkostwa na koncie właściciela.
- Przygotować TestFlight oraz instrukcję powrotu do poprzedniej wersji; uwzględnić, że cofnięcie klienta nie cofa schematu produkcyjnego.
- Opublikowanie aplikacji, płatne usługi i operacje na dawnych danych muszą być osobnymi, konkretnymi działaniami w uzgodnionym zakresie.

Odbiór: działająca aplikacja na produkcyjnym CloudKit, próby dwóch kont i potwierdzone egzekwowanie zadeklarowanych uprawnień.

## Rozbudowa i koszty

Profile tekstowe, zdjęcia i wiadomości mierzymy osobno. Awatary mają miniatury i cache; mapa nie pobiera galerii. Liczbę kont odróżniamy od liczby aktywnych użytkowników i operacji. Darmowa przestrzeń nie oznacza braku throttlingu ani darmowego działania dodatkowego backendu. Plan nie zakłada aktywacji Firebase Blaze.

## Oficjalne podstawy

- [Model baz, ról i środowisk CloudKit](https://developer.apple.com/icloud/cloudkit/designing/)
- [CKDatabase — wymóg iCloud przy zapisie](https://developer.apple.com/documentation/cloudkit/ckdatabase)
- [CKAsset — zdjęcia i pliki](https://developer.apple.com/documentation/cloudkit/ckasset)
- [Warunki członkostwa i CloudKit](https://developer.apple.com/programs/whats-included/)
