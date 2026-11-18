# CK-05a.2 — procesor retencji CloudKit

`CloudKitPublicRetentionProcessor` łączy [kolejkę wygaszania](RETENCJA_DANYCH_SPOLECZNOSCIOWYCH.md) z konkretnym klientem Web Services i checkpointem. Domyślnie jest wyłączony. Jest wewnętrznym API zaufanego kodu, bez trasy HTTP i bez parametru właściciela lub nazwy rekordu od użytkownika. W tym etapie nie jest jeszcze tworzony przez Runtime ani wywoływany przez alarm.

## Zakres operacji

Procesor sprawdza checkpoint, uzyskuje najwyżej 25 aktualnych lease z rejestru i utrwala nowy checkpoint przed operacjami na treści. Wyszukuje dokładnie te nazwy, pobierając wyłącznie schemaVersion, ownerKey, erased, deletionKey i retentionKey. Odpowiedzi muszą zachować dokładny zestaw nazw, typ rekordu, właściciela i prawidłowy tag. Obce pola metadanych lub blokada innej intencji powodują odmowę przed zapisem.

Brakujący rekord otrzymuje create pustej blokady. Istniejący otrzymuje replace po odczytanym tagu. Blokada zawiera schemaVersion, ownerKey, erased i retentionKey; nie zawiera pseudonimu, treści, GPS, utworu ani powodu zgłoszenia. Zabezpiecza także przed spóźnionym pierwotnym CREATE. Ponownie zastępujemy również już widoczną własną blokadę — samo ograniczone pobranie metadanych nie dowodzi braku innych pól.

Apple opisuje, że replace ustawia pominięte pola na null, a create odmawia nadpisania istniejącej tożsamości. [CloudKit Web Services — records/modify](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html). Dla replace wymagany jest recordChangeTag. [Types and Dictionaries](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html). Weryfikacja pełnej odpowiedzi dopuszcza usunięte wartości null; każda dodatkowa niepusta wartość blokuje potwierdzenie. Nie używamy forceReplace ani usuwania całej blokady.

Po powrocie sprawdzane są ponownie flagi, czas i lease. Dopiero dokładna pełna odpowiedź pozwala zakończyć lokalne zadanie. W partii nieatomowej poprawne rekordy mogą zostać potwierdzone mimo błędu innego rekordu; następnie checkpoint utrwala ich wynik i wywołanie zgłasza błąd. Konflikt nie uruchamia automatycznego zapisu w pętli. Niepewny wynik zachowuje zadanie; kolejna próba po wygaśnięciu lease ponownie bada blokadę.

## Cykl życia i zasoby

Jedna instancja ma jeden zajęty slot, domyślnie 8 s na wywołanie, z kontrolą czasu przed i po oczekiwaniu, flagi oraz sygnału anulowania. Zamknięcie wyniku nie zwalnia slotu przed rzeczywistym zakończeniem jego pracy, checkpointu, transportu i anulowania odpowiedzi. Dotyczy to także zależności ignorującej abort.

Klient publicznego CloudKit śledzi rzeczywiste zadania fetch/JSON i udostępnia wewnętrzny mechanizm oczekiwania na ich zakończenie. Checkpoint uwzględnia własną kolejkę. Anulowanie body zachowuje tę samą pierwszą obietnicę cancel; późniejsze wywołanie cancel na zamkniętym strumieniu nie jest zastępczym dowodem zakończenia pierwszego. Nieudany dowód zakończenia IO nie otwiera kolejnego slotu. Wspólny klient może zachować zajętość konserwatywnie również przez inne operacje aktywne w chwili oczekiwania.

JSON pozostaje ograniczony do 512 KiB; dodatkowy limit 4096 fragmentów odcina także patologiczne puste fragmenty. Fragmenty muszą być Uint8Array. To granice implementacji lokalnej, nie odbiór CPU/RSS lub limitów hostowanego Free.

## Obecność i usuwanie konta

Nowa obecność może zastąpić wyłącznie potwierdzoną blokadę swojego singletonu, po dokładnym tagu i markerze intencji. Stary requestID nie odnawia czasu. Niepotwierdzona lub zmieniona blokada odmawia publikacji. Normalne pełne pobranie przed ponownym zapisem sprawdza też brak dodatkowej treści.

Usuwanie konta ma pierwszeństwo. Może zastąpić własną dokładną blokadę retencji blokadą usuwania konta, również po utracie odpowiedzi poprzedniego procesu. Wyłączenie konta w trakcie odczytu lub zapisu przerywa potwierdzanie retencji. Jest to usunięcie pól treści; trwałe markery ownerKey i retentionKey nadal istnieją. Nie jest to dowód fizycznego usunięcia całego rekordu, kopii Apple lub assetu.

## Walidacja i dalszy odbiór

[Raport](evidence/public-retention-processor-local-tests.json) zawiera końcowe wyniki, hash kodu/logów i kontrolę negatywną. Nowe przypadki sprawdzają dokładne rekordy i właściciela, puste oraz istniejące rekordy, unknown/CAS, utracone odpowiedzi, pełne odpowiedzi z null albo z pozostawioną treścią, świeżą obecność, usuwanie konta, checkpoint, czas, timeout i zatrzymane anulowanie body. Dwa pierwsze testy ponownej obecności początkowo odmawiały wcześniej z powodu wygasłej sesji fixture; test jawnie loguje się ponownie i zachowuje właściwe ograniczenia autoryzacji.

Osobny test uruchamia rzeczywisty lokalny workerd/SQLite i podpisy ECDSA, z modelem Apple oraz wyłączoną siecią zewnętrzną. Potwierdza trzy blokady, stan erased dwóch niezmiennych operacji, zachowanie trwałego profilu, odmowę starej obecności i przyjęcie nowej. Konta i sesje są syntetyczne; to nie jest A/B iCloud, rzeczywisty CloudKit ani odbiór schematu/ról.

Następny CK-05a.3: alarm, budżety i uczciwy podział pracy z usuwaniem konta, domyślna flaga wyłączenia oraz kontrolowany odbiór Development. Pola retentionKey typów obecności/wiadomości/zgłoszeń wymagają przeglądu schematu przed użyciem usług. Nadal otwarte są retencja assetów, obsługa poufnych zgłoszeń/kontakt, oddzielna tożsamość serwisowa, dwa zwykłe konta oraz pozostałe kryteria migracji/TestFlight. Nie wykonano wdrożenia, aktywacji, zmiany kluczy/uprawnień/opłat, SDK telefonu ani zmian Production/Firebase.

Końcowa walidacja: **573/573 Node 22 i 573/573 Node 24**, 20 nowych funkcji i 130 MJS sprawdzonych na obu wersjach, 2 JSON. Kontrola negatywna daje 1 oczekiwany błąd przedwczesnego zwolnienia slotu. Pakiety Swift, UI i projekt aplikacji pozostają niezmienione; ich testów ani kompilacji Debug/Release nie liczono jako nowych przebiegów.
