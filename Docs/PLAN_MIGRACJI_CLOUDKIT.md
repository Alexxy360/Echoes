# Plan migracji Echoes do CloudKit

Aktualizacja: 14 listopada 2026. Kierunek wybrany przez właściciela: CloudKit. Status: CK-01/CK-02 w realizacji; zarejestrowano App ID i kontener, skonfigurowano podpisany Debug oraz wykonano rzeczywisty test prywatnej bazy jednego konta. Zwykły klient nadal korzysta z adaptera Firebase. Nie wdrożono schematu Production ani migracji danych użytkowników.

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

Postęp CK-01c: po konkretnych zgodach właściciela zarejestrowano App ID `mpvEcho.Echo`, utworzono i przypisano `iCloud.mpvEcho.Echo`, potwierdzono Dev w konsoli i zgodny profil/podpis Debug. Na iPhonie 15 Pro przeszło utworzenie, odczyt, kontrola metadanych autora i usunięcie losowego rekordu prywatnego. Preflight: 8 testów. Właściciel wybrał ograniczanie odczytu przez dodatkową usługę, najpierw z badaniem darmowego limitu. Postęp CK-01d: potwierdzono Workers Free na koncie, opisano limity i kontrakt pośrednika oraz zaimplementowano lokalne podpisywanie i ograniczoną próbę S2S Development (12 testów offline). [Projekt i limity](CLOUDKIT_POSREDNIK_FREE.md). Postęp CK-01e: po osobnej zgodzie zarejestrowano klucz S2S Development i wykonano pierwszą próbę lokalną. NOT_FOUND przy brakującym typie diagnostycznym; nieobecność testowego rekordu potwierdzona. Postęp CK-01f: po osobnej zgodzie dodano typ/pola, wyłączono dla niego standardowe role i przypisano rolę ograniczoną do tego typu tożsamości klucza. S2S dziedziczy prawa konta operatora; nie omija ACL. Końcowy test zapisu/odczytu/usunięcia przeszedł. Na produkcję potrzebna jest odrębna tożsamość serwisowa. Postęp CK-01g: przygotowano wyłączony prototyp HTTP Workers z pojedynczym przebiegiem w SQLite i 25 testami lokalnymi. Weryfikacja runtime pozostaje otwarta. CK-01h: w Cloudflare utworzono samą usługę Hello World na potwierdzonym Free, bez sekretów i bindings; publikacja prototypu została zatrzymana do konkretnej zgody. CK-01j: po wyjaśnieniu i wyraźnych zgodach wdrożono diagnostykę HTTP/SQLite w Workers Free. Kontrole dostępu przeszły, ale próba S2S zwróciła TRANSPORT_FAILED przez redirect:error nieobsługiwany w Workers. Apple potwierdziło nieobecność UUID. Poprawkę manual i 27 testów przygotowano; próba jest wyłączona, sekrety usunięte z aktywnej konfiguracji, token wdrożenia wygasł i został usunięty. CK-01k: po osobnej zgodzie w oknie do 30 min preflight Workers wykrył odrzucenie KeyObject w options.key. Zachowano walidację P-256, do sign() przekazano PEM i kontrola bez sieci przeszła. Następnie zapis/odczyt/usunięcie jednego rekordu CloudKit z hostingu przeszły; ponowienie zwróciło raport z SQLite. Próbę wyłączono i usunięto sekrety aktywnej wersji. W diagnostycznych metrykach brak przekroczeń CPU, lecz docelowe obciążenie i test dwóch kont nadal niezaliczone; logowanie użytkowników nie jest wdrożone i etap nie jest zakończony. [Dowody i pozostałe próby](CLOUDKIT_WERYFIKACJA.md), [ograniczony tryb diagnostyczny](CLOUDKIT_DIAGNOSTYKA.md).

1. Sprawdzić dostęp zespołu do iCloud/CloudKit, Bundle ID i istniejące kontenery. Nie wymyślać identyfikatora kontenera bez sprawdzenia konta Apple.
2. W środowisku Development przetestować odczyt/zapis dwóch użytkowników, zmianę konta iCloud, brak konta i niedostępność sieci. Nie publikować schematu produkcyjnego na tym etapie.
3. Sporządzić Docs/CLOUDKIT_ARCHITEKTURA.md: macierz kto może tworzyć, odczytywać, zmieniać i usuwać każdy typ danych. Zweryfikować bezpośrednie operacje klienta z pominięciem UI.
4. Udokumentować osobno granice: dostęp do publicznych rekordów spoza okolicy, modyfikacja własnych pól, limity antyspamowe, trwała blokada konta, ukrycie treści przez moderatora i poufność zgłoszeń.
5. Wybrać konkretną implementację elementów wymagających zaufanej logiki. Dodatkowy backend/operator jest opcją do sprawdzenia, nie automatycznie uruchamianą usługą płatną.

Odbiór: dowody testów dwóch kont i macierz uprawnień. Niespełnionych wymagań nie zastępujemy filtrem w UI. Jeśli wymagana jest dodatkowa usługa lub zmiana obietnic prywatności, przedstawiamy konkretny wariant, koszt i wpływ przed realizacją tej części. Pozostałe niezależne prace mogą być kontynuowane.

### CK-02 — adapter CloudKit i tożsamość

Postęp CK-02b: pakiet EchoesCloudKit podłączono jako lokalną zależność aplikacji; jego natywne źródło konta sprawdzono w podpisanym hoście Debug na prawdziwym iCloud. Tryb diagnostyczny pomija Firebase, mapę, GPS i muzykę. Zwykły CommunityClient nie jest jeszcze przełączony. Pełny CK-02 wymaga adaptera społecznościowego i pozostałych prób kont/sieci; nie kończy go pojedynczy udany test prywatny. CK-02c: dodano osobną kontrolę tożsamości bez operacji na rekordach; podpisana próba na iPhonie potwierdziła konto operatorskie. Właściciel ma na razie tylko jedno konto, więc test A/B oczekuje na inne konto i pozostaje obowiązkowy przed publikacją.

- Zachować niezależny EchoesCore i wstrzykiwanie zależności. Dopasować CommunityClient do CloudKit, zamiast kopiować do niego założenia Firebase.
- Dodać obsługę konta iCloud oraz izolację cache po zmianie tożsamości; nie traktować identyfikatora Firebase/IDFV jako identyfikatora CloudKit.
- Obsłużyć brak iCloud, restricted, czasową niedostępność, retryAfter, częściowe błędy, anulowanie, konflikty i idempotencję ponowienia.
- Wprowadzić schemat wersjonowany i indeksy w Development. Konfiguracja entitlements i podpisywania zgodna z rzeczywistym kontenerem.
- Zachować niezależny tryb demo. Prawdziwe konto iCloud nie może być zastępowane pozornym sukcesem demo.

Odbiór: testy kontraktu adaptera oraz prawdziwa próba konta iCloud na urządzeniu; testy mocków nie potwierdzają konfiguracji usługi.

Postęp CK-02d: lokalna serwerowa weryfikacja Apple identity tokenów RS256 i pobieranie publicznych kluczy ze stałego adresu, cache i limity odpowiedzi. Przeszło 13 nowych testów, cały gateway ma 40. Komponent nie jest podłączony do HTTP ani wdrożony; nonce sam nie zastępuje atomowego zużycia wyzwania, sesji i odwołania zgody. Nie zmieniano App ID ani iOS. [Zakres i dalszy odbiór](APPLE_LOGOWANIE_GATEWAY.md).

Postęp CK-02e: lokalne jednorazowe wyzwania i sesje w SQLite, z claim przed wymianą kodu, potwierdzeniem trwałości, skrótami tokenów, generacją wylogowania wszystkich i blokadą konta. 17 nowych testów, cały gateway ma 57. Bez wdrożenia/HTTP/iOS. Wymagany adapter wymiany kodu jest zależnością bez domyślnego sukcesu; prawdziwy Apple exchange, refresh/revocation, routing/limity między instancjami i retencja nadal oczekują. [Kryteria](SESJE_I_WYZWANIA_GATEWAY.md).

Postęp CK-02f: konkretny lokalny adapter wymiany kodu/refresh/revoke Apple, osobny ES256 client_secret oraz AES-256-GCM z wersjonowanym kluczem. Zaszyfrowany refresh jest trwale zapisany przed powiązaniem z kontem i wydaniem sesji; awarie nie ponawiają jednorazowego kodu. 23 nowe testy, cały gateway ma 80. Bez nowych uprawnień/sekretów, żądań Apple/Cloudflare i wdrożenia. Retencja/limity credential, cykl refresh/odwołania, konfiguracja Apple i natywny/Workers odbiór pozostają wymagane. [Kontrakt i granice](APPLE_OAUTH_I_TOKENY.md).

Postęp CK-02g: lokalne rotowane pary access/renewal z limitem bezwzględnym 30 dni, integralność HMAC i wykrywanie starej rotacji z unieważnieniem tej sesji. Kontrola Apple najwyżej raz na 24 h na konto; lease/revision, rezerwacja przestrzeni przed siecią i trwały staging nowego ciphertext przed sesją. Limity credential i cleanup w partiach mają kod/testy, ale brak alarmu. 36 nowych testów, cały gateway 116. Bez wdrożenia i prawdziwych tokenów; kolejka revoke/usunięcia danych, natywny przepływ/Keychain, HTTP i rzeczywiste próby nadal wymagane. [Kontrakt i granice](ODNAWIANIE_SESJI_GATEWAY.md).

Postęp CK-02h: lokalny proces usuwania ze świeżym purpose/nonce Apple, blokadą/generacją i znacznikiem odcinającym stare logowania, wąskim biletem odzyskiwania statusu, etapami public/private/Apple i ponowieniami. Migracja magazynu i osobny znacznik blokady operatora chronią przed pomyleniem celów wyzwania oraz obejściem bana przez usunięcie. 23 nowe testy, cały gateway 139. Rzeczywisty adapter kasowania CloudKit pozostaje obowiązkową, jeszcze niewdrożoną zależnością; private cleanup/Keychain i alarm także wymagają podłączenia. Nie wykonano żadnego usunięcia danych użytkowników ani zmian usług. [Kontrakt i granice](USUWANIE_KONTA_GATEWAY.md).

Postęp CK-02i: lokalnie połączono komponenty w zamknięty protokół HTTP, trwałe limity, jeden prywatny authority i alarm z lokalną retencją także bez kluczy dostawcy. Fair cursor zapobiega zatrzymaniu kolejki na pierwszych zadaniach. Osobny target echoes-community-development jest wyłączony; nie utworzono usługi/namespace/sekretów i nie zmieniono diagnostyki. 24 nowe testy, całość 163. Realny worker/request.cf/alarm, Apple i publiczny adapter CloudKit nadal wymagają odbioru. Następne prace: natywny klient/Keychain i połączenie przepływu; konfiguracja Apple/nowe uprawnienia oraz próba hostingu dopiero w konkretnym przygotowanym zakresie. [Kontrakt](BRAMKA_HTTP_DEVELOPMENT.md).

Postęp CK-02j: natywny klient auth HTTP, atomowy zapis pary w Keychain, single-flight rotacji, trwały znacznik nieznanego wyniku oraz odcięcie spóźnionych odpowiedzi. Helper Apple wiąże nonce/state bez zakresów profilu. 44/44 testy pakietu na macOS i udana lokalna kontrola Keychain w hoście Debug na symulatorze; Debug/Release kompilują się. Zwykły interfejs nadal nie używa nowej bramki. Następne prace: host logowania/credentialState/konto CloudKit, odzyskiwanie po limicie sesji oraz bilet usunięcia. Nie aktywowano SIWA/Workers ani nowych kluczy. [Zakres, dowody i granice](NATYWNA_SESJA_GATEWAY.md).

### CK-03 — trwały profil i model gotowy na zdjęcia

Postęp CK-03a: zaimplementowano prywatny rekord pseudonimu z kontrolą konfliktów i izolacją kont oraz lokalne przygotowanie avatarów/miniatur bez GPS/EXIF. Przeszło 9 testów profilu i 4 avatarów (łącznie 21 w pakiecie wraz z obsługą konta). Komponenty nie publikują danych i nie są jeszcze podłączone do UI; publiczny profil, CKAsset i testy dwóch kont nadal oczekują.

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

Powiązany postęp CK-02h: przygotowano lokalny sterownik usunięcia konta, bez pozornego sukcesu brakującego adaptera danych. Nie jest to odbiór CK-05 ani usunięcie starego konta Firebase. Kryteria publicznego/prywatnego CloudKit, operacji w toku i natywnego wznowienia nadal obowiązują.

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

Priorytet właściciela: **0 zł dodatkowych opłat za usługi na start**. Szczegóły: [strategia kosztów](STRATEGIA_KOSZTOW.md). Nie uruchamiać płatnego hostingu/API ani automatycznego upgrade bez konkretnej zgody. Zakres pierwszej wersji dopasować do darmowych możliwości, zachowując wymagania ochrony i moderacji. Rozbudowa po przychodach ma być możliwa przez dodanie potrzebnej usługi; nie zakładamy konieczności wymiany całej bazy. Budżet nie zatwierdza publiczności danych A/B. App ID i kontener zarejestrowano dopiero po osobnych, konkretnych zgodach właściciela.

Profile tekstowe, zdjęcia i wiadomości mierzymy osobno. Awatary mają miniatury i cache; mapa nie pobiera galerii. Liczbę kont odróżniamy od liczby aktywnych użytkowników i operacji. Darmowa przestrzeń nie oznacza braku throttlingu ani darmowego działania dodatkowego backendu. Plan nie zakłada aktywacji Firebase Blaze.

## Oficjalne podstawy

- [Model baz, ról i środowisk CloudKit](https://developer.apple.com/icloud/cloudkit/designing/)
- [CKDatabase — wymóg iCloud przy zapisie](https://developer.apple.com/documentation/cloudkit/ckdatabase)
- [CKAsset — zdjęcia i pliki](https://developer.apple.com/documentation/cloudkit/ckasset)
- [Warunki członkostwa i CloudKit](https://developer.apple.com/programs/whats-included/)
