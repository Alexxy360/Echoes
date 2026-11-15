# Porządkowanie lokalnych potwierdzeń — CK-02p

Stan: 15 listopada 2026. Zakończone potwierdzenie można świadomie usunąć z chronionego dziennika tego urządzenia, zwalniając miejsce w limicie 8 wpisów/64 KiB. Nie dodano automatycznego TTL, nadpisywania najstarszego wpisu ani kasowania niedokończonych zadań. Funkcja pozostaje w kontrolnym ekranie Debug; zwykła aplikacja nadal korzysta z Firebase.

## Warunki i skutki

Przycisk pojawia się wyłącznie przy własnych ukończonych checkpointach: potwierdzonym statusie serwera, prywatnym czyszczeniu, lokalnym czyszczeniu i własnym ACK. Globalny completed/ACK innego urządzenia nie wystarcza. Pending initial, niepewna recovery i inne zadanie recovery tego binding blokują usunięcie. Obce konto iCloud lub Apple binding nie może usunąć wpisu tą ścieżką.

Usunięcie ma osobne potwierdzenie „Usuń potwierdzenie”, bez arkusza Apple. Może działać po odwołaniu Apple. Nadal wymaga aktualnego natywnego właściciela iCloud, foreground oraz aktywnej konfiguracji. Alert wyjaśnia, że operacja dotyczy lokalnego zapisu i przypomina o wcześniejszym ręcznym odłączeniu Apple, jeśli było wymagane. Użytkownik może anulować bez zmiany magazynu.

`GatewayDeletionProgress` jest niezmiennym snapshotem. Wewnętrzny attemptID oraz cała jego treść przypinają potwierdzenie do konkretnej rotacji/statusu. Sterownik ponownie odczytuje i waliduje chroniony dziennik, sprawdza właściciela i zgodność snapshotu, po czym synchronicznie usuwa dokładnie jeden wpis i atomowo zapisuje pozostałe. Błąd pozostawia wcześniejszą wartość; można ponowić po odblokowaniu. Późna odpowiedź innego sterownika nie odtwarza brakującego wpisu.

Nie ma wywołań gateway, świeżej autoryzacji Apple, revoke, cleanera CloudKit lub plików. Kontrola natywnego konta iCloud nadal może odpytać Apple. Nie zmienia się ban, zadanie serwera, prywatny guard ani dane innego konta. Usunięcie lokalnego biletu nie przedłuża serwerowej retencji: późniejsze odzyskanie zależy od obecności zadania/receipt na serwerze i nowego dowodu Apple.

## Dowody i granice

162/162 testy Swift: 11 nowych (8 sterownika i 3 hosta). Obejmują zachowanie obcego wpisu, brak wywołań gateway/cleanera, niedokończone i niepewne zadania, rotację snapshotu, awarię zapisu/ponowienie, zmianę właściciela, uszkodzony storage, późną odpowiedź oraz rzeczywiste zwolnienie miejsca z pełnego dziennika. Pierwszy przebieg 162 testów miał jedną błędną asercję modelu: „zewnętrzny” sterownik dzielił natywną session i unieważniał revision przed zatwierdzeniem. Rozdzielono sesje, zachowując współdzielony storage; finalny przebieg przeszedł bez osłabiania kontroli produktu.

10/10 XCTest UI (1 nowy, 9 wcześniejszych) na iPhone 17 Pro/iOS Simulator 26.1. Nowy test sprawdza anulowanie, osobną etykietę potwierdzenia bez Apple oraz pusty dziennik po zatwierdzeniu. Dwa zrzuty przejrzano wizualnie. Debug z lokalnym podpisem ad-hoc; dowody kompilacji Release i hashe są w [raporcie](evidence/deletion-receipt-local-tests.json). Transporty konta/API są syntetyczne; nie ponawiano rzeczywistej kontroli Keychain z CK-02n.

To rozwiązanie jawnego porządkowania lokalnego, a nie pełna polityka retencji wszystkich danych. Automatyczne terminy, prywatny guard/legacy, prawdziwe logowanie, CloudKit/Workers i dwa zwykłe konta nadal wymagają odbioru. Nie uruchomiono usług, nowych uprawnień/sekretów, opłat, Production ani TestFlight i nie zmieniano danych użytkowników.

Końcowy przegląd wzmocnił również test późnej odpowiedzi: operacje mają niezależne native sessions, więc wykrywają brak trwałego wpisu. Po zmianie wyłącznie fixture cały zestaw Swift ponownie 162/162; źródła produktu i UI są identyczne z testowaną kompilacją.
