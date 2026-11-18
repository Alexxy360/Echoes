# CK-05a.1 — trwała kolejka wygaszania

Cel całego etapu: automatycznie usuwać treść danych tymczasowych również wtedy, gdy autor już nie otwiera aplikacji. Ukrycie po terminie, usunięcie pól z CloudKit i zachowanie zabezpieczeń przed spóźnionym zapisem to odrębne wymagania. Samo CloudKit nie otrzymało reguły TTL.

## Polityka

| Dane | Termin od danych rejestru serwera | Zachowanie po potwierdzonym usunięciu treści |
| --- | --- | --- |
| Obecność | 10 minut od ostatniej nowej intencji | Pusta blokada starej operacji; świeża intencja może ponownie użyć singletonu. |
| Wiadomość lokalna | 2 godziny od pierwotnego utworzenia | Tożsamość operacji pozostaje zużyta. Ponowienie jej nie odtwarza treści. |
| Zgłoszenie wiadomości | 30 dni od pierwotnego utworzenia | Tożsamość zgłoszenia pozostaje zużyta. |
| Profil, blokady, zdjęcia i wskazanie zdjęcia | Brak tej polityki TTL | Osobne reguły produktu i usuwania konta. |

Daty pochodzą wyłącznie z trwałego rejestru; klient nie ustala terminu. Ponowienie tej samej operacji zachowuje pierwotne daty. Wyłączenie obecności usuwa dane lokalizacji już przez zwykłe zastąpienie jej pól; kolejka nie dodaje kolejnego czasu widoczności.

## Wdrożone lokalnie

Rezerwacja nowego rekordu zapisuje w tej samej transakcji SQLite metadane kolejki: nazwę rekordu, hash dokładnej intencji i termin. Kolejka nie zawiera pseudonimu, wiadomości, GPS, powodu zgłoszenia ani pliku. Starszy rejestr jest uzupełniany partiami do 100 rekordów. Dojrzałe zadania uzyskują trwałe lease na 60 s, po najwyżej 25 w partii. Zapamiętany kursor obraca pracę również po otwarciu nowej instancji i przy nierozwiązanych wcześniejszych zadaniach.

Wygasły rekord przestaje być czytelny i zapisywalny także przed uzupełnieniem kolejki. Rozpoczęte czyszczenie blokuje późne settle oraz zmianę obecności do czasu potwierdzenia jego blokady. Lease sprawdza dokładny rekord/intencję, token, czas, stan i aktywne konto przed i po utrwaleniu. Cofnięcie zegara poniżej początku lease albo jego wygaśnięcie odmawia zakończenia. Jest to kontrola tego lease, nie globalna gwarancja monotoniczności zegara serwera.

Potwierdzenie dotyczy wyłącznie wewnętrznego API zaufanego procesora; nie istnieje trasa HTTP przyjmująca od użytkownika taki dowód. Procesor musi wcześniej odczytać i zweryfikować dokładne pola oraz tag CloudKit. W tej części procesor nie jest jeszcze podłączony i nie wykonano zdalnego czyszczenia.

Wiadomość lub zgłoszenie po potwierdzeniu otrzymuje lokalny stan erased; metadane intencji są usuwane. Obecność zachowuje potwierdzony tag pustego singletonu i wymaga nowej intencji do ponownej publikacji. Rozpoczęcie usuwania konta odcina lease retencji, a zakończenie jego partii usuwa też odpowiednie zadania kolejki. Pierwszeństwo ma usunięcie konta.

## Plan dalszego połączenia

1. **CK-05a.2 — procesor CloudKit.** Sprawdzić checkpoint i lease, pobrać wyłącznie metadane dokładnych znanych rekordów, użyć create pustej blokady przy braku rekordu albo warunkowego replace po tagu. Zbadać pełną odpowiedź, zachować unknown/conflict i ponownie sprawdzić wszystkie bariery. Obsłużyć współbieżne usuwanie konta oraz późniejszą świeżą obecność. Osobne sloty mają obejmować rzeczywisty koniec zależności po anulowaniu. Testy obejmą rzeczywisty lokalny workerd/SQLite z modelami dostawców.
2. **CK-05a.3 — alarm, limity i aktywacja.** Podłączyć do istniejącego alarmu, zachować pracę lokalną bez kluczy, ograniczyć wywołania dostawców i zapewnić sprawiedliwy udział z usuwaniem kont. Domyślna flaga zdalnego czyszczenia pozostanie wyłączona. Przygotować konkretne typy/pola i test Development do akceptacji; lokalne testy nie zatwierdzają wdrożenia.
3. **Dalsza retencja zdjęć i zgłoszeń.** Rozwiązać nieprzypięte assety i późne uploady, poufne zgłoszenia oraz ich obsługę i kontakt. Zweryfikować rzeczywiste zachowanie CloudKit, limity Free, odnowienia i zatrzymanie po wygaśnięciu konfiguracji.

Pusta blokada CloudKit ma zachować wyłącznie schemaVersion, ownerKey, erased i retentionKey. Nie planujemy usuwać jej tak, by opóźniony CREATE mógł odtworzyć treść. Usunięcie pól jest inną operacją niż usunięcie całego rekordu albo fizyczne usunięcie pliku z infrastruktury Apple; odbiór będzie te wyniki rozróżniał. Nowe pola blokad wymagają osobnego przeglądu schematu Development.

Retencja nie zwalnia trwałych tożsamości i nie resetuje limitów. Obecne pułapy kontrolowanego Development nadal obejmują 1000 zapisanych tożsamości na konto i 10 000 w całym rejestrze, wliczając blokady po wygaszeniu. To ograniczenie targetu testowego, wymagające dalszego projektu pojemności przed szerokim wydaniem.

## Dowody i granice odbioru

[Raport lokalny](evidence/public-retention-state-local-tests.json) zawiera wyniki testów, SHA źródeł/logów i kontrolę negatywną. Przypadki obejmują terminy, brak przedłużania retry, brak odczytu/zapisu po terminie, uzupełnianie starego rejestru, limit i wyłączność lease, cofnięcie czasu, obce rekordy, opóźnione settle, nowe intencje obecności, zachowane limity, usuwanie konta i wznowienie kolejki z plikowego SQLite.

SQLite w tych nowych testach jest lokalny; konta, tokeny i dostawcy są syntetyczni. Istniejąca pełna regresja zawiera lokalne workerd, ale nie stanowi jeszcze dowodu wykonania nowego procesora retencji. Brak wdrożenia, aktywacji, nowych sekretów/uprawnień/opłat, testu SDK telefonu, zmian Production/Firebase lub publikacji TestFlight. iOS i zależności nie zostały zmienione. Pełny cel migracji pozostaje otwarty.

Końcowa walidacja: **553/553 Node 22 i 553/553 Node 24**, 15 nowych funkcji, kontrola negatywna 1 oczekiwany błąd. Przejrzano składnię 125 modułów MJS na obu wersjach i 2 plików JSON; końcowy dodatkowy przypadek wyłączenia konta przeszedł również sprawdzenie składni na obu wersjach. Nie powtarzano niezmienionych testów iOS/Core ani kompilacji aplikacji.
