# Trwały bilet i prywatne czyszczenie — CK-02n

Stan z 14 listopada 2026: lokalna implementacja sterownika, dziennika Keychain i połączenia z cleanerem CK-03b. Nie podłączono jeszcze arkusza usuwania ani zwykłego UI. Nie uruchomiono usług i nie usuwano danych użytkowników. Zwykła aplikacja nadal korzysta z Firebase.

Aktualizacja CK-02o: dodano host, potwierdzenie, selektywne zamknięcie sesji i kontrolny ekran Debug z konkretnym cleanerem cache. Historyczny opis poniżej zachowuje stan odbioru CK-02n. Zwykły interfejs nadal Firebase; [aktualny zakres i testy](NATYWNE_USUWANIE_UI.md).

## Trwałość i przestrzeń

`KeychainGatewayDeletionStorage` jest oddzielny od magazynu sesji. Wylogowanie/tombstone sesji nie kasuje biletu. Wpis jest ograniczony do origin, kontenera i środowiska; używa Data Protection Keychain, WhenUnlockedThisDeviceOnly, synchronizable=false, bez zapasu w UserDefaults/pliku. Przy utracie urządzenia bilet wymaga świeżego odzyskania przez Apple; nie przenosi się przez synchronizację iCloud.

Atomowy dziennik mieści do 8 żądań i 64 KiB. Każde żądanie jest związane z natywnym Apple userID, skrótem właściciela iCloud, UUID zadania i autorytatywnym kontem Echoes. Zawiera tylko potrzebny bilet, status, kursor SDK i checkpointy. Nie zapisuje JWT, kodu ani nonce Apple. Wersja, namespace, format biletu, identyfikatory i spójność checkpointów są sprawdzane przy odczycie. Błąd/pełny magazyn nie oznaczają pustego konta i nie nadpisują wcześniejszych danych.

Nie ma jeszcze automatycznej retencji lokalnych receipts. Limit zabezpiecza wzrost, ale wymaga obsługi/polityki przed wydaniem. Nie wolno usuwać starszych potwierdzeń tylko po to, by ukryć błąd zapisu. Końcowa retencja prywatnego guarda CK-03b także pozostaje do wdrożenia.

## Przebieg

`GatewayDeletionController` działa na MainActor. Host dostarcza prawdziwe, obowiązkowe callbacki zamknięcia dostępu i czyszczenia lokalnych danych oraz konfigurację aktywacji. Nie ma domyślnego sukcesu. Nowy bilet jest trwale zapisany przed callbackiem zamknięcia dostępu i przed pierwszym żądaniem HTTP. Błąd zamknięcia dostępu lub zapisu zatrzymuje dispatch.

Świeży `AppleGatewayProof` musi pochodzić z natywnego, powiązanego nonce/state arkusza. Sterownik sprawdza Apple userID i termin wyzwania, a serwer JWT/purpose/właściciela. Nie odtwarza dowodu po restarcie. Nieznany wynik pierwszego żądania można sprawdzić tym samym biletem, bez kolejnego arkusza. Ponowienie świeżej próby początkowej zachowuje ten sam niepotwierdzony bilet.

Odzyskiwanie zapisuje recoveryPending i nowy losowy attemptID przed siecią. W tym stanie stare bilety tego natywnego właściciela nie autoryzują czyszczenia. Kolejny świadomy dowód wykorzystuje ten sam marker, nie mnoży wpisów. Odpowiedź jest zapisywana tylko dla aktualnej próby. Dwa sterowniki z niezależnymi sesjami iCloud nie mogą przez spóźnioną odpowiedź podmienić nowszego biletu. Odzyskane to samo zadanie zachowuje własny kursor i checkpointy. Niepewna rotacja wymaga kolejnego świeżego dowodu; brak automatycznego retry.

Każda operacja odświeża natywny stan iCloud. Wybrany journalID musi należeć do bieżącego binding; wyniki sprawdzają accountID i deletionID. `suspend` synchronicznie ukrywa dane i odcina spóźnione odpowiedzi bez kasowania dziennika. Host musi wywoływać go na background/lock i zmianie iCloud. Samo odwołanie zgody Apple nie unieważnia możliwości dokończenia usuwania poprawnym biletem. Pełne podłączenie tych zdarzeń w hoście/UI jest nadal przed nami.

## Prywatne kroki i potwierdzenie

`advance` wykonuje najwyżej jedną stronę prywatnego cleanera. `NativePrivateProfileDatabase` implementuje wymagany protokół, bez zastępczego erasure. Sterownik pobiera status zaakceptowanego zadania; callback przed mutacjami ponownie sprawdza bilet/status oraz dokładną przestrzeń iCloud/konta. Zwykła sesja ani client-selected UUID nie upoważniają tej ścieżki.

Oddzielne checkpointy oznaczają usuniętą zawartość strefy, wyczyszczone lokalne dane i potwierdzenie ACK tego urządzenia. Kursor zapisuje się po potwierdzonej stronie. Zmiana konta, błędny kursor, konflikt lub nieznany wynik nie stają się sukcesem. Wznowienie skanu po wygaśnięciu tokenu jest jawne; samo wybranie restartu nie wykonuje SDK ani pętli ponowień.

Lokalne dane są usuwane dopiero po zakończeniu prywatnego czyszczenia i tylko w przekazanej przestrzeni. Callback musi naprawdę odciąć późne lokalne zapisy i wyczyścić jej pliki/cache; obecnie nie jest jeszcze połączony z AppServices. Błąd lokalny zachowuje checkpoint prywatny i zabrania ACK. Po nieznanym wyniku ACK wolno ponowić ten idempotentny endpoint, bez ponownego kasowania już potwierdzonych stron i plików.

Server device-acknowledged/completed z innego urządzenia nie pomija lokalnego czyszczenia tego urządzenia. `GatewayDeletionProgress.completed` wymaga zarówno server completed, jak i wszystkich trzech własnych checkpointów oraz braku niepewnego odzyskiwania. manual-required pozostaje osobnym wynikiem Apple. Minimalny guard nadal istnieje; nie deklarujemy pełnego opróżnienia prywatnej bazy ani fizycznego usunięcia CKAsset na serwerach Apple.

## Dowody i dalsza integracja

125/125 testy Swift na macOS (27 nowych): rzeczywisty kod sterownika/kodeków i jawne modele API/SQLite-strefy. Utrata odpowiedzi i zapisu, restart, strony/kursory, ACK, inne urządzenie/konto, nieprawidłowy magazyn, cap/aktywacja, równoległe odzyskiwanie i połączenie z NativePrivateProfileDatabase. Model atomic/change tag nie jest testem CloudKit. Negatywna kontrola w osobnej kopii wyłącza jeden guard odpowiedzi; test wyścigu rzeczywiście zakończył się trzema błędami oczekiwań. Oryginalny kod nadal przeszedł 125/125. [Raport wykonania](evidence/deletion-flow-local-tests.json).

Debug/Release kompilowane z projektem z Git; do testu Keychain Debug podpisano lokalnie ad-hoc, Release bez podpisywania. Kompilacja bez podpisywania nie wystarcza do testu Keychain: pierwsza próba zwróciła -34018 (errSecMissingEntitlement), odrzucając już odczyt. Lokalna kontrola Security.framework wymaga podpisanego ad-hoc wariantu symulatora z istniejącym projektem, bez nowych grantów usług. Podpisana kontrola zwróciła passed: oba usunięcia status=0 i ponowny odczyt status=-25300 (brak wpisu). Kontrola w aplikacji Debug sprawdza losowy bilet, zastąpienie, większy wpis, limit i niezależność od wylogowania sesji oraz atrybuty ochrony. Usuwa wyłącznie swoje losowe wpisy. Wynik to kontrola Keychain, nie prawdziwego konta/usługi, hosta usuwania ani odbiór wizualny UI.

Następnie: host i arkusz Apple dla delete/recovery, potwierdzenia i stany UI, rzeczywiste zamknięcie dostępu/plików w AppServices, wybór/wznawianie właściwego biletu przed przywróceniem sesji, retencja receipts/guarda i legacy. Nadal wymagane są realne Apple/CloudKit/Workers, publiczny adapter erasure i dwa zwykłe konta. Bez tego nie ma pełnego odbioru usuwania ani gotowości TestFlight.
