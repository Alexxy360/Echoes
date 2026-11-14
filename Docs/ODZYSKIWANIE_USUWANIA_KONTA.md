# Bilet i odzyskiwanie usuwania — CK-02m

Stan z 14 listopada 2026: zaimplementowano lokalny kontrakt backendu i natywny klient HTTP. Nie uruchomiono nowej usługi i nie usuwano danych użytkowników. Magazyn biletu w Keychain, sterownik procesu oraz połączenie z prywatnym cleanerem/UI są następnym etapem.

## Dlaczego osobne odzyskiwanie

Bilet zapisany przed pierwszym żądaniem pozwala sprawdzić nieznany wynik bez kolejnego dowodu Apple. Jednak utrata urządzenia lub lokalnego wpisu uniemożliwiała odzyskanie istniejącego zadania. Nowy UUID oznaczał próbę utworzenia drugiego zadania; ograniczenie SQLite odrzucało ją jako niedostępność. Teraz świeża próba nowego usunięcia przy istniejącym zadaniu zwraca DELETION_IN_PROGRESS i wskazuje potrzebę odzyskiwania. Nie tworzy duplikatu.

Osobne purpose=deletion_recovery i POST /v1/account/deletion/recover przyjmują challengeID, identityToken oraz opcjonalne expectedAccountID. Nie przyjmują deletionID, authorizationCode ani Authorization/Bearer. Weryfikacja używa istniejącego verifiera Apple i atomowego claim wyzwania. Nie wymienia kodu i nie wydaje sesji/renewal. Ban i pełny limit credential nie odbierają właścicielowi możliwości kontynuowania usuwania.

Wybór zadania odbywa się wyłącznie według zweryfikowanego sub. Najpierw wybierane jest zadanie w toku; w jego braku najnowszy zakończony receipt z ostatnich 30 dni. expectedAccountID tylko sprawdza zgodność, nie wybiera cudzego ani starszego zadania. Brak zadania zwraca NO_DELETION (404), bez tworzenia konta lub zadania. Receipt starego konta zachowuje jego UUID, także gdy właściciel utworzył później nowe konto; odzyskiwanie nie dotyka tej nowej rejestracji.

## Rotacja i niepewny wynik

Transakcja zachowuje deletionID, accountID, kolejkę, lease, terminy i wszystkie postępy. Zmienia jedynie skrót biletu oraz recovery_order i zużywa wyzwanie. Nowy statusToken (UUID zadania + 256 losowych bitów) trafia do odpowiedzi dopiero po sync. W bazie pozostaje tylko skrót. Poprzedni token od razu przestaje działać; również inne urządzenie z tym tokenem może wymagać ponownego odzyskania.

Bariera wykorzystuje istniejący monotoniczny auth_event_order, a nie wyłącznie zegar. Dowód wydany przed utworzeniem zadania lub ostatnią rotacją nie wymieni biletu. Spośród już wydanych równoległych wyzwań tylko pierwsza zakończona rotacja może wygrać. Nowe wyzwanie po niej działa również w tej samej milisekundzie. Migracja deletion-recovery-order-v1 dodaje kolumnę i odcina stare wyzwania istniejących zadań; ponowne otwarcie bazy jej nie powtarza. Dodano indeks wyszukiwania receipt właściciela.

Utrata odpowiedzi lub błąd sync nie są sukcesem klienta. W takim przypadku trzeba świadomie ponowić odzyskiwanie z nowym wyzwaniem i arkuszem Apple. Nie ma automatycznego replay dowodu, kodu ani rotacji. Istniejący poprawny bilet nadal umożliwia status/ACK bez zwykłej sesji i bez wymagania świeżej autoryzacji Apple po jej odwołaniu.

Wszystkie statusy usuwania zawierają teraz accountID pochodzące z zadania. UUID jest potrzebny do przypisania prywatnej strefy; nie jest sekretem ani dowodem dostępu. Tylko odpowiedź recover zawiera nowy statusToken. Zwykłe status/create/ACK nie ujawniają go. Dostęp do tych odpowiedzi nadal wymaga właściwego biletu albo świeżego dowodu właściciela.

## Natywny kontrakt

GatewayAccountDeletionAPI jest oddzielone od access/renewal. GatewayHTTPClient obsługuje oba purpose, request/recovery/status/private ACK z tym samym zamkniętym HTTPS transportem, limitami, brakiem przekierowań/cache/cookies i brakiem automatycznych ponowień. Create/idempotent request wymagają 202, pozostałe odpowiedzi 200. Nieznane stany, inny protocolVersion, obcy identyfikator lub sprzeczne completed są odrzucane.

GatewayDeletionTicket tworzy UUID i sekret przez systemowy SecRandomCopyBytes, waliduje kanoniczny base64url i format również przy odkodowaniu. Opis/debug/reflection redagują bilet. Kodowane JSON nadal zawiera sekret — przeznaczony do Keychain/HTTPS, nigdy logów. GatewayDeletionProof nie zastępuje natywnego sprawdzenia Apple/iCloud; obowiązek powiązania pozostaje po stronie przyszłego sterownika. ActivatedGatewayAccountDeletionAPI sprawdza zaufany origin i termin Development przy każdym wywołaniu. Nie włączono konfiguracji w bundlu.

device-acknowledged jest oświadczeniem urządzenia, nie dowodem CloudKit. Status ten z innego urządzenia nie potwierdza wyczyszczenia lokalnych danych bieżącego urządzenia. completed z manual-required pozostaje odrębnym stanem: nie oznacza potwierdzonego odwołania całej autoryzacji Apple. UI musi to zachować. Prywatny cleaner CK-03b pozostawia minimalny guard; jego retencja i końcowe usunięcie nadal niegotowe.

## Testy i następny etap

196/196 testów Node, w tym 12 nowych odzyskiwania i 4 HTTP: realne lokalne SQLite i verifier RS256, syntetyczne Apple/JWT i adapter danych. Testowano utracony bilet, stare/równoległe wyzwania, zmianę konta, ban/limity, cel dowodu, nieznany wynik, rollback, reopen/migrację, receipt starego konta/retencję, pola HTTP i planowanie przed mutacją.

98/98 testów pakietu Swift, w tym 8 nowych: losowy/redagowany bilet, kanoniczne odkodowanie, dokładny kontrakt HTTP, zgodność konta/zadania, sprzeczne stany, brak retry i aktywacja. Debug/Release kompilowane bez podpisywania z project.pbxproj z Git; zastaną zmianę oryginalnego projektu zachowano. [Raport](evidence/deletion-recovery-local-tests.json).

Następnie: oddzielny trwały wpis Keychain, zapis przed wysłaniem i wznowienie po restarcie, blokady współbieżności/zmiany konta, natywny arkusz usuwania/odzyskiwania, autoryzacja zaakceptowanego biletu dla dokładnej przestrzeni iCloud, prywatne strony/kursor i cache przed ACK, uczciwe stany UI oraz końcowa retencja. Nadal wymagane są prawdziwe Apple/Workers/CloudKit i dwa zwykłe konta. To nie jest pełny odbiór usuwania ani gotowość TestFlight.
