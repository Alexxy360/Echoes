# Bariera anulowania zgłoszenia zdjęcia — CK-05d.1c.2b

Cel: pozwolić późniejszemu formularzowi bezpiecznie zwolnić nierozstrzygniętą próbę. Po utracie połączenia samo NOT_FOUND/unconfirmed nie dowodzi, że stare CREATE nigdy nie dotrze. Usunięcie tylko lokalnego journala albo zdalnego rekordu pozwoliłoby na spóźnione odtworzenie starego zgłoszenia. Potrzebna jest trwała, pozbawiona treści bariera pod tym samym recordName.

Stan 2b.1: wewnętrzna warstwa repozytorium/rejestru/retencji i lokalny odbiór. Nie ma jeszcze trasy cancel, kompozycji Authority/Edge, zmiany DTO/journala iOS, formularza lub aktywacji. To nie jest działający interfejs anulowania dla użytkownika. Dotychczasowe zewnętrzne DTO nadal znają accepted/unconfirmed; nowy wewnętrzny cancelled wymaga podłączenia w 2b.2 przed użyciem tej ścieżki poza testami.

## Własna niezmienna tożsamość

Wewnętrzny cancelAvatarReport przyjmuje token, pierwotny requestID i zaufany synchroniczny authorizeMutation. Wylicza recordName wyłącznie z konta sesji i requestID, bez wskazania osoby, wersji, powodu, GPS, obrazu lub dowolnej nazwy rekordu od klienta. Wymaga dokładnego true; false/undefined/Promise odmawia przed rezerwacją lub IO. Konto i generacja są ponownie sprawdzane po await. To repozytorium wywoływane tylko przez zaufany coordinator; nie zapewnia własnego admission/deadline. Kolejny etap musi objąć je istniejącym zatrzymanym slotem i rzeczywistym deadline/drain.

Rejestr rezerwuje dokładnie tę tożsamość i trwały hash cancellationKey. Dwie addytywne kolumny SQLite przechowują marker i potwierdzony tag; nie tworzą nowych praw CloudKit. Istniejące dane pozostają zachowane, a migracja jest idempotentna. Startup odrzuca niezgodne fazy/tagi/rodzaje lub marker niezwiązany z requestID w nierozstrzygniętym stanie. Nieznany wcześniej nonce zużywa jeden zwykły wpis rejestru, objęty licznikiem i checkpoint. Istniejąca próba przechodzi w erasing, przez co stary writer traci zgodę na zakończenie i odczyt. Limit 1000 wpisów/konto i 10000 globalnie nadal obowiązuje, łącznie z barierami. Pełny rejestr odmawia nowego nonce, lecz może zamknąć już zarejestrowaną próbę.

Checkpoint jest weryfikowany, następnie rezerwacja utrwalana i kotwica przesuwana przed mutacją. Starszy snapshot SQLite nie może pominąć już potwierdzonej rezerwacji bariery i ponownie otworzyć nonce.

## Trwały zapis i dowód

Brak rekordu oznacza CREATE bariery pod pierwotnym recordName. Istniejący własny raport jest zweryfikowany z pełnymi polami i pierwotnym hash, po czym zastąpiony przez exact CAS z bieżącym recordChangeTag. Nie ma DELETE, force lub zastępowania innego konta. Konflikt pozostaje niepotwierdzony; osobna jawna próba może wznowić tę samą barierę. Spóźniony CREATE starej treści dostaje EXISTS.

Bariera ma wyłącznie schemaVersion=1, ownerKey, erased=1 i retentionKey=cancellationKey. Marker używa osobnej domeny hash. To pola już zawarte w lokalnej propozycji EchoesAvatarReportV1; pliku schematu/rolom nie dodano niczego i nie importowano go w Apple. Bariera zachowuje metadata potrzebne do powstrzymania spóźnionego zapisu, nie kopię zdjęcia lub powodu.

Cancelled jest zwracane dopiero po kontroli całej odpowiedzi CloudKit: dokładny własny recordName/typ/ownerKey, poprawny tag i dokładnie cztery pola bariery bez resztek treści. Dopiero wtedy lokalny rejestr przechodzi w erased i zeruje requestID, logicalKey, payloadHash, czasy i generację. Zachowuje wyłącznie trwałą tożsamość bariery/tag. Jeszcze po checkpoint kontrolowane są konto i rejestr. Fałszywa odpowiedź z dodatkowym reason nie jest potwierdzeniem.

## Utrata ACK, retencja i usunięcie konta

Recovery nie tworzy ani nie nadpisuje bariery lub raportu. Może utrwalić lokalne potwierdzenie dopiero po pełnym odczycie dokładnej zdalnej bariery. Brak rekordu, dawny raport lub dodatkowa treść dają unconfirmed; sam lokalny znacznik settled nie zastępuje istnienia bariery. Ten sam UUID innego konta wskazuje jego odrębną tożsamość i nie odkrywa cudzego zgłoszenia.

Niedokończone anulowanie pozostaje objęte pierwotnymi 30 dniami retencji. Stan erasing nie wyłącza terminu ani backfill/schedule. Jeżeli aplikacja nie wróci, procesor retencji po terminie zakłada tę samą barierę cancellation i potwierdza ją dopiero po dokładnych polach/tagu. Czytelnik i stary mutator pozostają odcięci. Rezerwacja nieznanego nonce również ma ograniczony termin, a anulowanie już wygasłego raportu może przekształcić potwierdzoną barierę retencji w barierę cancellation bez odtwarzania treści.

Usuwanie konta zastępuje także pending cancellation własną barierą usunięcia. Metadata anulowania już zamkniętych rekordów są czyszczone w partiach do 25; remaining pozostaje true aż do końca. Nie dotyka to innego konta. Zdalny bariera bez treści pozostaje zgodnie z istniejącym modelem powstrzymywania spóźnionych zapisów.

## Odbiór i dalsze części

[Dowody lokalne](evidence/avatar-report-cancellation-local-tests.json) obejmują delayed CREATE, unknown nonce, CAS conflict, pełny/wadliwy fence, lost ACK, zmianę generacji sesji, rollback SQLite, erasure, pierwotną retencję, backfill i limity. Lokalny rzeczywisty workerd/SQLite/podpisy/repozytorium/procesor retencji potwierdziły oba rodzaje bariery, read-only recovery bez dodatkowej mutacji i wygaśnięcie pozostawionej próby. Provider Apple i konta są syntetyczne, outbound workerd zablokowany. Re-instancja Store używa tego samego procesu i bazy; nie jest to odbiór restartu/power loss lub Cloudflare PITR.

2b.2: zamknięte HTTP/Runtime cancel i typed cancelled, osobna domyślnie wyłączona aktywacja, quota/drain/deadline i ponowne sprawdzenie uprawnień. iOS musi zapisać cancelling przed wysłaniem, zachować ten sam nonce i dopiero terminalny cancelled pozwala zakończyć anulowanie. Jeśli w fazie cancelling recovery pokaże accepted lub unconfirmed, nie jest to dowód anulowania i próba musi pozostać zajęta. Bez ślepego ponowienia pierwotnej treści. Potem host/świadomy formularz 1c.3 i osobny operator zdjęć.

Brak Swift/Core/UI/CI/deps lub ponowień ich buildów/testów w 2b.1. Brak nowych usług, aktywacji, kluczy, ról, sekretów, opłat, telefonu, zmian Development/Production w Apple, Cloudflare, Firebase lub TestFlight. Pełne rzeczywiste schema/SIWA/ordinary A-B/query/ASSET/CDN/Free/retencja/urządzenia pozostają obowiązkowe.
