# Trwała intencja decyzji zgłoszenia — CK-05c.4b.1

Aktualny odbiór CK-05d.2c.1 i migracja starego not-applied: [zamykanie niepewnych prób](ZAMYKANIE_NIEPEWNYCH_DECYZJI_MODERATORA.md). Historyczne dowody pierwszego etapu pozostają poniżej; nowa kontrola aplikacyjnego Keychain obejmuje retiring → ponowne otwarcie → retired.

`GatewayReportReviewJournal` zapisuje jedną intencję decyzji moderatora w lokalnym zakresie: origin bramki, kontener/Development, konto Echoes, konto iCloud i natywna tożsamość Apple. Zmiana sesji tego samego konta nie zmienia klucza magazynu. Zakres ten nie nadaje roli moderatora i nie zastępuje autoryzacji hosta lub serwera.

To część przepływu [natywnego klienta zgłoszeń](NATYWNY_KLIENT_POUFNYCH_ZGLOSZEN.md). Host i połączenia z Runtime/usuwaniem konta dodaje [CK-05c.4b.2a](STEROWNIK_MODERACJI_ZGLOSZEN_IOS.md). Panel i faktyczna prezentacja materiału pozostają w CK-05c.4b.2b. Dziennik jest współdzielony wyłącznie w izolowanym Runtime Development i sam nie uruchamia HTTP; zwykłe wejście aplikacji nadal korzysta z adaptera Firebase.

## Przejścia i nieznany wynik

1. `open` obraca trwałą dzierżawę zakresu; starsza instancja nie może potwierdzić lub nadpisać nowszego wpisu. `peek` jest odczytem bez tworzenia rekordu i bez zmiany dzierżawy.
2. `prepare` zapisuje dokładne `reportID`, `decisionID`, `verdict`, `contentHash`. Nie przechowuje tekstu/powodu zgłoszenia, profilu, GPS, tokenu, inspectionID, potwierdzenia odczytu ani prawa do ponowienia zapisu.
3. `dispatched` wymaga dokładnego prepared i zmienia jego lokalną revision. Przyszły host musi ukończyć ten zapis i ponownie potwierdzić konto/ekran/sesję przed HTTP. Błąd IO lub niejednoznaczny zapis nie uprawnia do wysłania decyzji.
4. `resolve` przyjmuje wyłącznie wynik recovery związany ze wszystkimi czterema zapisanymi polami. Przechowuje confirmed z poprawną serwerową revision albo not-applied/superseded/retired bez revision. Tylko confirmed, superseded i retired są terminalne. Not-applied zachowuje dispatched lub retiring. Dawny resolved/not-applied jest odczytywany jako dispatched z tym samym UUID i lokalną revision, bez przepisywania lub kasowania w odczycie. Wynik nie daje uprawnienia do nowej decyzji.
5. `retiring` utrwala jawną intencję zamknięcia przed tokenem i HTTP, z tym samym decisionID. Recovery nie tworzy serwerowej bariery.
6. `acknowledge` usuwa tylko dokładny resolved z terminalnym wynikiem i po jawnym potwierdzeniu operatora w hoście. Odtworzony z tego samego chronionego magazynu terminalny wynik otrzymuje świeży lokalny handle; nie wymaga ponownej decyzji ani sieci, również po wygaśnięciu serwerowej historii. Stary handle nie może go usunąć. Nierozstrzygniętego wpisu nie można zastąpić lub skasować tym poleceniem. Nowe otwarcie aplikacji nie odtwarza treści ani inspekcji i nie uruchamia automatycznego retry.

Zapis jest weryfikowany przez odczyt zwrotny. Wyjątek przed/po zapisie lub niezgodność odczytu daje zamknięty błąd; zachowany wpis wymaga późniejszego odczytu i recovery tych samych identyfikatorów. Uszkodzona, zbyt długa, obca lub rozszerzona struktura jest odrzucana bez automatycznej naprawy/usunięcia.

## IO, odcięcie dostępu i usuwanie

Synchronous read/check/write/readback wykonuje osobna szeregowa kolejka GCD poza MainActor. Nie ma await wewnątrz tej operacji. Frontend obserwowalny na MainActor kontroluje dzierżawę i epokę przed/po każdym await. Wcześniej anulowane polecenie nie rozpoczyna IO. Anulowanie rozpoczętego zapisu nie udaje jego cofnięcia: odrzuca późny wynik i zachowuje identyfikatory, jeżeli magazyn je zapisał.

`fence` odcina bieżącą dzierżawę natychmiast; spóźniona odpowiedź nie otwiera nowego konta. Bariera usuwania konta obejmuje dokładne natywne powiązanie i opcjonalny accountID. Erasure usuwa wszystkie origin/natywne powiązania dokładnego prywatnego właściciela w osobnym namespace. Błąd usuwania nie odblokowuje odczytu. Do 32 zapamiętanych właścicieli i 32 barier; przekroczenie zamyka przyjmowanie operacji przez instancję zamiast zapominać wcześniejsze bariery. Jawne sprzątanie nadal działa również po zapełnieniu tej pamięci.

Natywny adapter używa usługi Keychain `mpvEcho.Echo.gateway.report-review.v1`, odmiennej od avatar-review, community i credentials. Wymusza Data Protection Keychain, `WhenUnlockedThisDeviceOnly`, brak synchronizacji oraz do 4096 B. Query usuwania zawiera usługę i hash właściciela, bez nieograniczonego kasowania Keychain. Hash scope i owner w payload chronią przed podmianą rekordów między zakresami; nie są grantem dostępu ani szyfrowaniem aplikacyjnym.

## Weryfikacja i granice

Testy wymuszają niejednoznaczny zapis, blokujące IO, anulowanie, zmianę konta/usuwanie podczas zapisu, stare dzierżawy/revision, wszystkie wyniki, zły payload i limity barier. Odpowiedź recovery wygenerowana przez rzeczywisty lokalny Runtime/SQLite przechodzi przez klienta Swift do dziennika. Provider i tożsamości są modelowane.

Osobny test UI w procesie aplikacji Debug używa rzeczywistego lokalnego Keychain: zapis/dispatch/recovery, odczyt przez nową instancję dziennika, atrybuty, odmowa zapisu ponad limit, dwa origin jednego właściciela i zachowanie wpisu drugiego właściciela po usunięciu pierwszego. Wszystkie identyfikatory są losowe i syntetyczne; końcowe sprzątanie potwierdza nieobecność wszystkich trzech własnych wpisów. Odpowiedź recovery w tej próbie pochodzi z lokalnego transportu Swift, bez sieci. Początkowy test bezpośrednio w procesie pakietowego XCTest dostał -34018 (errSecMissingEntitlement); przeniesienie do hosta aplikacji potwierdziło działanie adaptera bez dodawania pominięcia. Simulator potwierdza funkcjonalny round trip i atrybuty; nie dowodzi szyfrowania ani odmowy odczytu na zablokowanym fizycznym telefonie. Odtworzenie instancji nie jest testem utraty zasilania lub twardego restartu procesu. Dokładne wyniki i hashe: [dowody](evidence/report-review-journal-local-tests.json).

Nie wykonano nowej operacji w CloudKit/Cloudflare, testu Development lub na fizycznym urządzeniu, nadania roli, utworzenia/przekazania klucza, aktywacji usługi, płatności, publikacji Production/TestFlight ani usuwania Firebase. Pełna migracja nadal wymaga hosta/panelu, rzeczywistego SIWA/Runtime, zwykłych kont A/B, regionalnych query/ASSET/CDN oraz odbioru Free i urządzeń zgodnie z planem.
